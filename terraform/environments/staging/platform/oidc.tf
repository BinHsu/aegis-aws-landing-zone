# -----------------------------------------------------------------------------
# IRSA — IAM Roles for Service Accounts
# -----------------------------------------------------------------------------
# EKS issues each cluster an OIDC identity provider URL. AWS STS does not
# trust that OIDC issuer automatically — we have to register it as an IAM
# OIDC provider in this account before any IRSA role can use it.
#
# Once registered, any IAM role whose trust policy references this provider
# plus a ServiceAccount subject condition can be assumed by a pod that
# mounts the projected OIDC token. Per ADR-013 "Workload IAM", IRSA is the
# chosen mechanism for all pod → AWS API access in Phase 3 (Pod Identity
# migration is tracked in the Phase 5 backlog).
#
# The OIDC provider created here is consumed by:
#   - Phase 3c (Karpenter PR)     → Karpenter controller IAM role
#   - Phase 3c (Ingress+GitOps)   → AWS Load Balancer Controller + ArgoCD
#   - Phase 4 (Observability)     → CloudWatch Logs / Prometheus scrape role
# -----------------------------------------------------------------------------

data "tls_certificate" "cluster_oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "cluster" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer

  client_id_list = ["sts.amazonaws.com"]

  # Thumbprint of the root CA that signs the OIDC JWKS endpoint. EKS
  # historically used a DigiCert-signed endpoint; AWS recommends pinning
  # the leaf or intermediate thumbprint discovered via TLS. The
  # hashicorp/tls provider's `data.tls_certificate` does exactly that.
  thumbprint_list = [data.tls_certificate.cluster_oidc.certificates[0].sha1_fingerprint]

  tags = {
    Name = "${local.cluster_name}-eks-irsa"
  }
}
