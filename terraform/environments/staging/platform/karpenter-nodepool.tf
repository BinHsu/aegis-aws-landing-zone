# -----------------------------------------------------------------------------
# Karpenter default NodePool + EC2NodeClass
# -----------------------------------------------------------------------------
# A NodePool declares the constraints Karpenter uses when choosing which
# EC2 instances to launch for pending pods (instance types, zones, capacity
# type — spot vs on-demand). An EC2NodeClass declares AWS-specific launch
# parameters shared across NodePools (subnet / SG selection, AMI family,
# instance profile).
#
# Defaults chosen here:
#   - Spot capacity first, On-Demand fallback disabled (lab cost tuning).
#     Workloads that require stable capacity should define their own
#     NodePool with `capacity-type: on-demand`.
#   - Instance size capped at 4 vCPU / 16 GiB. A lab does not need 8xlarge
#     and this prevents a misbehaving deployment from inadvertently
#     launching large Spot instances.
#   - Bottlerocket AMI family — minimal, immutable, container-optimized.
#     Reduces node attack surface vs AL2023.
#   - Subnets and security groups discovered by tag. The network layer
#     (staging/network) tags private subnets with
#     `kubernetes.io/role/internal-elb = 1` — we reuse that tag here.
#   - 30-minute node lifecycle — nodes are recycled at least every 30
#     minutes to pick up AMI patches and security updates.
#
# Implementation note: these are CRD instances installed by the Karpenter
# Helm chart. We use `kubectl_manifest` (gavinbunney/kubectl) rather than
# hashicorp/kubernetes's `kubernetes_manifest` because the latter requires
# the CRD schema to be reachable at PLAN time. On a cold apply the cluster
# does not exist yet, so plan errors with "Failed to construct REST client:
# no client config". The kubectl provider defers validation to apply time
# (just runs `kubectl apply` with the raw YAML), which is what we need for
# a single-pass bootstrap apply. See Incident 10 in docs/incidents.md.
# -----------------------------------------------------------------------------

resource "kubectl_manifest" "karpenter_default_ec2nodeclass" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "default"
    }
    spec = {
      amiFamily = "Bottlerocket"

      # Use the latest Karpenter-resolved Bottlerocket AMI for the cluster's
      # Kubernetes minor version. The `@latest` alias follows AWS's published
      # SSM parameters and picks up patched AMIs on next node roll.
      amiSelectorTerms = [{
        alias = "bottlerocket@latest"
      }]

      subnetSelectorTerms = [{
        tags = {
          "kubernetes.io/role/internal-elb" = "1"
        }
      }]

      securityGroupSelectorTerms = [{
        tags = {
          "aws:eks:cluster-name" = aws_eks_cluster.main.name
        }
      }]

      role = aws_iam_role.karpenter_node.name

      # User-level tags only. Karpenter's admission webhook REJECTS tag
      # prefixes it reserves for internal use:
      #   - `kubernetes.io/cluster/*`    (Karpenter auto-applies `=owned`
      #                                   to every EC2 it launches)
      #   - `karpenter.sh/*`             (Karpenter internal bookkeeping)
      #   - `karpenter.k8s.aws/*`        (Karpenter internal)
      #
      # Note also: `karpenter.sh/discovery` is the tag that should go on
      # the *subnets* and *security groups* (consumed by
      # subnetSelectorTerms / securityGroupSelectorTerms above), NOT on
      # EC2NodeClass.spec.tags. The network layer handles subnet tagging.
      #
      # See docs/incidents.md Incident 14 for the webhook-rejection story.
      tags = local.tags
    }
  })

  depends_on = [helm_release.karpenter]
}

resource "kubectl_manifest" "karpenter_default_nodepool" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "default"
    }
    spec = {
      template = {
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default"
          }

          # Instance-class constraints.
          requirements = [
            {
              key      = "karpenter.k8s.aws/instance-category"
              operator = "In"
              values   = ["t", "m", "c"] # general-purpose / compute
            },
            {
              key      = "karpenter.k8s.aws/instance-generation"
              operator = "Gt"
              values   = ["2"] # no gen-2 or older (t2, m3, etc.)
            },
            {
              key      = "karpenter.k8s.aws/instance-cpu"
              operator = "In"
              values   = ["2", "4"] # cap at 4 vCPU
            },
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64"] # arm64 can be added once workloads support it
            },
            {
              key      = "kubernetes.io/os"
              operator = "In"
              values   = ["linux"]
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = ["spot"] # lab cost tuning — no on-demand fallback
            },
            {
              key      = "topology.kubernetes.io/zone"
              operator = "In"
              values   = local.primary_zones
            },
          ]

          # Nodes expire and recycle after 30 minutes. Forces regular
          # AMI patch pickup and prevents Spot instances from staying
          # attached indefinitely.
          expireAfter = "30m"
        }
      }

      # When no pods need a node, Karpenter deletes it after 30 seconds.
      # Aggressive vs production (where you'd keep warm capacity); appropriate
      # for a lab that teardowns between sessions.
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "30s"
      }

      # Hard ceiling — even if many pods pile up, never launch more than
      # 4 vCPU and 16 GiB total across this pool. This is the cost
      # back-stop: anything past this limit blocks scheduling rather than
      # spending money.
      limits = {
        cpu    = "4"
        memory = "16Gi"
      }
    }
  })

  depends_on = [
    kubectl_manifest.karpenter_default_ec2nodeclass,
  ]

  # On destroy: wait for Karpenter to actually deprovision the EC2 instances
  # it created in response to this NodePool's delete before letting
  # downstream resources (helm_release.karpenter) get destroyed. Without
  # this, the NodePool delete submits asynchronously, Terraform immediately
  # destroys the Karpenter controller, and any in-flight EC2 termination is
  # abandoned — the EC2s become orphans that block subnet deletion later
  # in teardown. See docs/incidents.md Incident 19.
  #
  # The second kubectl block (scale + wait for pod delete) closes the gap
  # that Incident 22 exposed: `helm uninstall` returns as soon as the
  # pod-delete API call is accepted, NOT after the pod has actually
  # terminated. Terraform then parallelizes onward to destroy the Fargate
  # profile — which force-kills the still-terminating Karpenter pod
  # mid-finalization, leaking any in-flight EC2. Scaling Karpenter to 0
  # here guarantees the pod is gone before helm_release.karpenter destroys.
  #
  # The `|| true` tail on each command is deliberate: if the cluster is
  # already gone (e.g., destroy is recovering from a partial earlier
  # attempt), we don't want these waits to wedge the whole teardown. The
  # workflow-level sweep in terraform-teardown-workload.yml is the safety
  # net for that scenario — and for CI, where the local-exec runs without
  # a kubeconfig and is effectively a no-op. See docs/incidents.md Incident 22.
  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      kubectl wait --for=delete nodeclaim --all --timeout=10m || true
      kubectl scale deployment karpenter -n karpenter --replicas=0 || true
      kubectl wait --for=delete pod -l app.kubernetes.io/name=karpenter -n karpenter --timeout=5m || true
    EOT
  }
}
