# -----------------------------------------------------------------------------
# CoreDNS — explicit EKS addon with Fargate compute type
# -----------------------------------------------------------------------------
# Without this resource, EKS auto-installs CoreDNS with `computeType: ec2`.
# The pods are born before the `kube-system` Fargate profile exists, so they
# do NOT pass through the Fargate mutating admission webhook and thus lack
# the Fargate toleration. Even when the Fargate profile is later created
# with a matching selector, the existing CoreDNS pods sit Pending forever
# because:
#
#   - No EC2 nodes yet (Karpenter hasn't provisioned)
#   - Fargate node has taint `eks.amazonaws.com/compute-type=fargate` that
#     the unmutated CoreDNS pods cannot tolerate
#
# This breaks the whole cluster because:
#
#   - Karpenter controller (on Fargate) can't resolve sts.amazonaws.com
#     (DNS is down) → Karpenter crashes → no EC2 nodes get provisioned
#   - Every downstream pod that needs DNS sits idle
#
# The fix: take ownership of the CoreDNS addon via `aws_eks_addon` and set
# `computeType = Fargate` in configurationValues. EKS reconfigures the
# Deployment to include the Fargate-compatible pod template before the
# default pods ever get stuck.
#
# `resolve_conflicts_on_create = OVERWRITE` lets us take over the
# EKS-auto-installed addon; without it, `aws_eks_addon` fails on
# "addon already exists".
#
# See docs/incidents.md Incident 16 for the discovery story. This resource
# exists precisely so forkers do NOT re-experience that incident.
# -----------------------------------------------------------------------------

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"

  # Take over the auto-installed addon rather than conflicting with it.
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    # The critical field: tells EKS to schedule CoreDNS pods onto Fargate
    # nodes matching the kube-system Fargate profile (fargate.tf). Without
    # this, EKS defaults to ec2 scheduling and the bootstrap race in
    # Incident 16 recurs.
    computeType = "Fargate"

    # Fargate pods require explicit resource requests/limits. CoreDNS at
    # lab scale is comfortable at the Fargate minimum (0.25 vCPU, 512 MB).
    resources = {
      limits = {
        cpu    = "0.25"
        memory = "512Mi"
      }
      requests = {
        cpu    = "0.25"
        memory = "512Mi"
      }
    }
  })

  # Must wait for the Fargate profile to exist before flipping CoreDNS to
  # Fargate mode — otherwise EKS has no landing zone for the pods.
  depends_on = [aws_eks_fargate_profile.kube_system]
}
