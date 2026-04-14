# staging/platform

The EKS platform layer for `aegis-staging`. Contains the EKS cluster, Fargate profiles for system pods (CoreDNS, Karpenter controller), the IRSA OIDC provider, Access Entries mapping the CI role and operator SSO role to Kubernetes cluster-admin, and **Karpenter v1** (controller on Fargate + default NodePool + EC2NodeClass).

The AWS Load Balancer Controller and ArgoCD are intentionally NOT in this layer — they land in Phase 3c PR 3 so each can be reviewed and applied independently.

---

## Before you touch this layer

**Read `docs/runbooks/002-eks-access.md` first.** That runbook is the authoritative source for:

- Session-start public-IP check (required for every session that touches the cluster)
- Connectivity failure diagnostic order (IP → TLS reachability → SSO → kubeconfig → Access Entries)
- Procedure for updating `public_access_cidrs` when the operator's ISP reassigns the public IP

Skipping the runbook and debugging `kubectl` failures "from the cluster outwards" is the single biggest time sink in this layer. See the runbook's section 4 for the reasoning.

---

## Apply prerequisites

This layer reads from three other layers:

| Dependency | Provides | Failure mode if missing |
|---|---|---|
| `shared/ipam` | CIDR pool for `staging/network` | `staging/network` plan errors — platform plan never reaches here |
| `staging/network` | VPC + private subnets for Fargate | `check "network_layer_applied"` fails in `config.tf` |
| `management/bootstrap` | PlatformAdmin SSO assignment → reserved role in staging | `check "sso_platform_admin_role_exists"` fails in `access-entries.tf` |

Apply ordering is enforced operationally by the CI workflow split:

1. `terraform-apply-baseline.yml` applies `management/bootstrap`, `shared/*`, `staging/bootstrap` on every merge to main.
2. `terraform-apply-workload.yml` (workflow_dispatch, approval-gated) applies `staging/network` → `staging/platform` → `staging/workloads` in order.

---

## Cost profile

Apply triggers ~$0.30/hr ongoing while the cluster is running:

| Component | Approximate cost while running |
|---|---|
| EKS control plane | $0.10/hr (~$73/month always-on) |
| Fargate (CoreDNS + Karpenter controller, ~3 pods) | ~$0.12/hr |
| Karpenter-managed Spot EC2 (when there are workloads) | ~$0.01/hr per small instance |
| SQS (Karpenter interruption queue) | $0 at lab message volume |
| EventBridge rules (4x) | $0 at lab event volume |
| CloudWatch Logs (5 log types at lab traffic) | pennies/day |
| KMS keys (2) | $2/month (fixed, $0.03/day not teardown-able) |

See ADR-013 "Consequences" for the full cost table and why teardown discipline is load-bearing.

---

## Teardown

End of session:

```bash
gh workflow run terraform-teardown-workload.yml -f env=staging
gh run watch   # approve in UI
```

This destroys `staging/workloads` → `staging/platform` → `staging/network` in order. The platform destroy itself takes 5–10 minutes (cluster drain + Fargate profile removal + KMS key scheduling).

**The two KMS keys in this layer have a 30-day deletion window and continue costing $2/month until the window elapses.** This is intentional — shortening the window to speed up teardown would risk unrecoverable secrets loss if teardown was triggered in error. Accept the $2/month residual as the price of recoverable KMS destruction. See ADR-004 "Consequences → Design implications" for the parallel rationale applied to IPAM's release lag.

---

## Files

```
staging/platform/
├── backend.tf                    # S3 state backend
├── versions.tf                   # Terraform + provider constraints (aws, tls, helm, kubernetes)
├── providers.tf                  # AWS + Helm + Kubernetes providers (exec plugin for EKS auth)
├── config.tf                     # Reads config/landing-zone.yaml + cross-layer state
├── cluster.tf                    # IAM + KMS + log group + aws_eks_cluster
├── fargate.tf                    # Fargate pod execution role + profiles
├── oidc.tf                       # IRSA OIDC provider
├── access-entries.tf             # CI role + operator SSO role → cluster-admin
├── karpenter-iam.tf              # Node role + controller IRSA role + EC2_LINUX access entry
├── karpenter-interruption.tf     # SQS queue + EventBridge rules for Spot interruption handling
├── karpenter-helm.tf             # Karpenter controller Helm release on Fargate
├── karpenter-nodepool.tf         # Default NodePool + EC2NodeClass (Spot, 4 vCPU cap, Bottlerocket)
├── outputs.tf                    # Consumed by LB Controller / ArgoCD PRs
└── README.md                     # This file
```

---

## Related docs

- ADR-013 `docs/decisions/013-eks-architecture.md` — EKS design rationale
- ADR-009 `docs/decisions/009-lifecycle-and-teardown-strategy.md` — workflow split
- Runbook 002 `docs/runbooks/002-eks-access.md` — operator access contract
