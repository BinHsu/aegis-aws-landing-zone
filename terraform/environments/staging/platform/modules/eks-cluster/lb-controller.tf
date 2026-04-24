# -----------------------------------------------------------------------------
# AWS Load Balancer Controller — Helm install (per-cluster)
# -----------------------------------------------------------------------------
# ⚠️  Admission webhook ordering policy (Incidents 17 + 33)
#
# LBC installs a cluster-wide MutatingWebhookConfiguration (`mservice.elbv2.k8s.aws`)
# that intercepts EVERY `Service` resource at admission — not just `type=LoadBalancer`.
# Until LBC's own Pod is Ready and its backing Service has Endpoints, Service
# creations elsewhere in the cluster fail with "no endpoints available for
# service aws-load-balancer-webhook-service".
#
# **Rule: any helm_release in this module that creates K8s Services must add**
# **`helm_release.aws_lb_controller` to its `depends_on` block.**
#
# Current compliance (as of Incident 33 fix, PR following 2026-04-24):
#   ✅ argocd.tf — depends_on aws_lb_controller (Incident 17 original fix)
#   ✅ cert-manager-helm.tf — added at Incident 33
#   ✅ external-secrets-helm.tf — added at Incident 33
#   ✅ kyverno-helm.tf — added at Incident 33
#   ✅ kube-state-metrics.tf — added at Incident 33
#   ⏭️ karpenter-helm.tf — installed BEFORE LBC (no race)
#   ⏭️ prometheus-operator-crds.tf — CRDs only, no Service
#   ⏭️ alloy.tf — transitive via external_secrets; explicit safer but not failing today
#
# Future helm_release additions: audit at PR time for Service-creating charts
# and add the depends_on before merge. This policy is the load-bearing
# prevention for a multi-cluster webhook race that wasted a full cold-apply
# slot + forced manual K8s cleanup (Incident 33).
# -----------------------------------------------------------------------------
resource "helm_release" "aws_lb_controller" {
  provider = helm.this

  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.8.2" # tracks controller v2.8.2 — match to policy file

  values = [
    yamlencode({
      clusterName = aws_eks_cluster.main.name

      serviceAccount = {
        create = true
        name   = "aws-load-balancer-controller"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.lb_controller.arn
        }
      }

      # Explicit region + vpcId vs auto-discovery — CI-friendly, no IMDS reliance.
      region = var.region_name
      vpcId  = var.vpc_id

      replicaCount = 1

      resources = {
        requests = { cpu = "100m", memory = "128Mi" }
        limits   = { cpu = "200m", memory = "256Mi" }
      }
    }),
  ]

  depends_on = [
    aws_iam_role_policy.lb_controller,
    helm_release.karpenter,
    kubectl_manifest.aegis_cluster_admin_binding,
  ]
}
