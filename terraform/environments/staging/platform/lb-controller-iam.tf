# -----------------------------------------------------------------------------
# AWS Load Balancer Controller — IAM (IRSA)
# -----------------------------------------------------------------------------
# The controller running in-cluster needs to call AWS APIs to manage ALBs,
# NLBs, Security Groups, and their tag-based lifecycle. The IAM role below
# is trusted ONLY by the `kube-system/aws-load-balancer-controller` service
# account via the cluster's OIDC provider — no other pod can assume it.
#
# The attached policy is the canonical policy published by the
# kubernetes-sigs/aws-load-balancer-controller project. It is deliberately
# lengthy; the length is the point — every action is scoped by resource
# tags or by AWS request conditions, following least-privilege. When the
# upstream policy changes (usually with each minor controller release),
# the JSON file should be refreshed and the controller chart version pinned
# below should be bumped in lockstep.
#
# Source: https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.8.2/docs/install/iam_policy.json
# Controller chart version: see lb-controller.tf
# -----------------------------------------------------------------------------

resource "aws_iam_role" "lb_controller" {
  name = "${local.cluster_name}-aws-lb-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.cluster.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_host}:aud" = "sts.amazonaws.com"
          "${local.oidc_host}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "lb_controller" {
  name   = "${local.cluster_name}-aws-lb-controller"
  role   = aws_iam_role.lb_controller.id
  policy = file("${path.module}/lb-controller-policy.json")
}
