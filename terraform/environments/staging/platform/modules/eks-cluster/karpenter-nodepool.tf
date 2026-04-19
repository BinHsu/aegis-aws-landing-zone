# -----------------------------------------------------------------------------
# Karpenter default NodePool + EC2NodeClass (per-cluster)
# -----------------------------------------------------------------------------
# Per-cluster CRD instances. Each cluster has its own default NodePool with
# topology constrained to its own region's AZs (passed via var.availability_zones).
#
# See the original top-level karpenter-nodepool.tf (pre-refactor) for the full
# commentary on instance sizing, AMI family, spot-only choice, 30-minute
# recycle, and the Incident 10 (kubectl_manifest vs kubernetes_manifest) story.
# -----------------------------------------------------------------------------

resource "kubectl_manifest" "karpenter_default_ec2nodeclass" {
  provider = kubectl.this

  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "default"
    }
    spec = {
      amiFamily = "Bottlerocket"

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

      # User-level tags only. Karpenter reserves kubernetes.io/cluster/*,
      # karpenter.sh/*, karpenter.k8s.aws/* — see Incident 14.
      tags = var.tags
    }
  })

  depends_on = [helm_release.karpenter]
}

resource "kubectl_manifest" "karpenter_default_nodepool" {
  provider = kubectl.this

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

          requirements = [
            {
              key      = "karpenter.k8s.aws/instance-category"
              operator = "In"
              values   = ["t", "m", "c"]
            },
            {
              key      = "karpenter.k8s.aws/instance-generation"
              operator = "Gt"
              values   = ["2"]
            },
            {
              key      = "karpenter.k8s.aws/instance-cpu"
              operator = "In"
              values   = ["2", "4"]
            },
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64"]
            },
            {
              key      = "kubernetes.io/os"
              operator = "In"
              values   = ["linux"]
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = ["spot"]
            },
            {
              key      = "topology.kubernetes.io/zone"
              operator = "In"
              values   = var.availability_zones
            },
          ]

          expireAfter = "30m"
        }
      }

      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "30s"
      }

      limits = {
        cpu    = "4"
        memory = "16Gi"
      }
    }
  })

  depends_on = [
    kubectl_manifest.karpenter_default_ec2nodeclass,
  ]

  # Destroy-time Karpenter quiesce — see Incident 19 + 22 for the full story.
  # In multi-region, operator's kubectl context points at one cluster; the
  # other region's quiesce gracefully degrades via `|| true`. The workflow-
  # level teardown sweep is the safety net that catches orphaned resources.
  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      kubectl wait --for=delete nodeclaim --all --timeout=10m || true
      kubectl scale deployment karpenter -n karpenter --replicas=0 || true
      kubectl wait --for=delete pod -l app.kubernetes.io/name=karpenter -n karpenter --timeout=5m || true
    EOT
  }
}
