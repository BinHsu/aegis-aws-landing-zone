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
# -----------------------------------------------------------------------------

# Server-side apply is required for Karpenter v1 manifests because the
# API ships OpenAPI schema validation that `kubernetes_manifest` uses at
# plan time. Requires a running cluster to plan.
resource "kubernetes_manifest" "karpenter_default_ec2nodeclass" {
  manifest = {
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

      tags = merge(local.tags, {
        "karpenter.sh/discovery"                             = aws_eks_cluster.main.name
        "kubernetes.io/cluster/${aws_eks_cluster.main.name}" = "owned"
        "topology.kubernetes.io/region"                      = local.primary_region
      })
    }
  }

  depends_on = [helm_release.karpenter]
}

resource "kubernetes_manifest" "karpenter_default_nodepool" {
  manifest = {
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
  }

  depends_on = [
    kubernetes_manifest.karpenter_default_ec2nodeclass,
  ]
}
