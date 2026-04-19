# -----------------------------------------------------------------------------
# IRSA — IAM OIDC identity provider (ADR-013 "Workload IAM")
# -----------------------------------------------------------------------------
data "tls_certificate" "cluster_oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "cluster" {
  provider = aws.this

  url = aws_eks_cluster.main.identity[0].oidc[0].issuer

  client_id_list = ["sts.amazonaws.com"]

  thumbprint_list = [data.tls_certificate.cluster_oidc.certificates[0].sha1_fingerprint]

  tags = {
    Name = "${var.cluster_name}-eks-irsa"
  }
}

locals {
  # OIDC issuer URL minus the scheme — used in IRSA trust-policy conditions.
  oidc_host = replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")
}
