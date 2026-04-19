# -----------------------------------------------------------------------------
# AWS Load Balancer Controller — IAM (IRSA)
# -----------------------------------------------------------------------------
# The controller running in-cluster needs to call AWS APIs to manage ALBs,
# NLBs, Security Groups. The role below is trusted ONLY by the
# kube-system/aws-load-balancer-controller service account via this cluster's
# OIDC provider — no other pod can assume it.
#
# Attached policy: canonical policy from the kubernetes-sigs project (see
# lb-controller-policy.json). Refresh the JSON in lockstep with the chart
# version in lb-controller.tf.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "lb_controller" {
  provider = aws.this

  name = "${var.cluster_name}-aws-lb-controller"

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
  provider = aws.this

  name   = "${var.cluster_name}-aws-lb-controller"
  role   = aws_iam_role.lb_controller.id
  policy = file("${path.module}/lb-controller-policy.json")
}
