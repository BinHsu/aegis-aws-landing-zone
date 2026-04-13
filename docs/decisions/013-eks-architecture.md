# 013. EKS Architecture

## Status
Accepted

## Context
Phase 3 builds an EKS cluster in `aegis-staging` as the runtime for the `aegis-core` workload. Several load-bearing decisions need to be locked before any EKS Terraform runs: cluster version, node provisioning mechanism, control plane exposure, workload IAM model, image registry, TLS certificate provider, and GitOps bootstrapping.

Each decision interacts with the others. Choosing Karpenter for nodes changes what bootstraps Karpenter itself. Choosing ACM for TLS changes whether cert-manager is installed. Choosing public container images changes whether NAT data transfer dominates cost. This ADR resolves the interactions coherently.

## Decision

**EKS version — 1.32.**

EKS 1.32 was the current default for new clusters as of the Phase 3 start date. AWS standard support for 1.32 runs into 2027, which matches the expected project lifetime. Kubernetes 1.32 supports the full set of GA APIs required by Karpenter v1, ArgoCD 2.x, and AWS Load Balancer Controller — no need to pin to an older version for compatibility.

**Node provisioning — Karpenter only, Karpenter itself on Fargate.**

No managed node groups. Karpenter v1 provisions EC2 instances directly based on pod scheduling pressure, using the `NodePool` and `EC2NodeClass` CRDs. Node scaling is binpack-based and reacts within seconds, which matches the lab teardown cadence: when all workloads are destroyed, Karpenter terminates the underlying EC2 within minutes, zeroing EC2 cost automatically.

Karpenter itself is a pod and needs to run somewhere. Running it on the nodes it provisions creates a chicken-and-egg bootstrap problem. The two clean solutions are a tiny managed node group for system pods (Karpenter, CoreDNS, kube-proxy) or running on EKS Fargate. This project uses **Fargate for Karpenter and CoreDNS**. Fargate eliminates the managed node group (one less Terraform resource and one less thing to forget to tear down), costs $0.04/hour for a Karpenter-sized pod, and makes the bootstrap story trivial: the cluster starts empty and Karpenter provisions the first EC2 node on demand.

**Control plane endpoint — public + private.**

The EKS API server is accessible via both public (for `kubectl` from the operator's laptop) and private (for in-cluster components) endpoints. Fully private endpoints would require either a bastion host, a VPN, or SSM port forwarding for operator access — all of which add complexity without security benefit in a single-operator lab. Access to the public endpoint is restricted to the operator's IP range via `public_access_cidrs`, which is read from config at deployment time.

**Workload IAM — IAM Roles for Service Accounts (IRSA).**

Every workload pod that needs AWS permissions uses IRSA, not node instance roles. The EKS cluster has an OIDC identity provider; pods annotate their ServiceAccount with a role ARN; AWS SDKs exchange the projected OIDC token for temporary credentials. This is the AWS-recommended pattern and eliminates the need for any long-lived credentials anywhere — consistent with ADR-001's "no static credentials" principle at the pod level, just as OIDC federation enforces it at the CI/CD level.

EKS Pod Identity (the 2023 alternative to IRSA) is considered for a future upgrade but IRSA remains the more portable and better-documented pattern for this project's scope. Pod Identity migration is tracked in Phase 5 backlog.

**Operator access — EKS Access Entries with IAM Identity Center.**

EKS Access Entries (the replacement for the older aws-auth ConfigMap) map AWS IAM principals to Kubernetes RBAC. The `PlatformAdmin` permission set in Identity Center is mapped to the `cluster-admin` ClusterRole. No IAM users, no aws-auth ConfigMap, no static kubeconfig — `aws eks update-kubeconfig` produces a token from the current SSO session. When the operator's SSO session expires, `kubectl` stops working, which is the correct behavior.

**Image registry — ECR for all workload images.**

All container images used by workloads deploy to an ECR repository in the `aegis-staging` account. Public images (CoreDNS, Karpenter, ArgoCD, AWS Load Balancer Controller) are pulled from their original sources during initial install via NAT Gateway; after deployment they are cached in ECR through the EKS image puller. Custom workload images (from `aegis-core`) are built by GitHub Actions and pushed to ECR.

ECR storage costs approximately $0.10/GB/month — pennies for a lab with a handful of images. Cross-AZ pull charges ($0.01/GB) are offset by same-region pull being otherwise free. Compared to pulling public Docker Hub images through NAT, ECR saves NAT data processing fees ($0.045/GB) and eliminates Docker Hub's unauthenticated rate limit (100 pulls per 6 hours), which Karpenter-driven scale-up can easily hit.

**TLS certificate provider — ACM for public endpoints.**

Public-facing services terminate TLS at an AWS-provided load balancer (ALB via AWS Load Balancer Controller) using ACM-issued certificates. ACM is free for public certs, renews automatically, and requires no outbound internet egress from the cluster. The ArgoCD UI, the aegis-core application ingress, and any future public endpoint all use this pattern.

cert-manager is **not** installed in Phase 3. It is deferred to Phase 5 when service mesh mTLS creates an actual requirement for in-cluster certificate issuance. Installing cert-manager earlier solely for the ArgoCD UI cert would be a premature complexity — ACM + ALB covers that case with less operational overhead.

**Ingress controller — AWS Load Balancer Controller.**

AWS Load Balancer Controller watches for `Ingress` and `Service type=LoadBalancer` resources and provisions ALBs or NLBs. ALBs integrate natively with ACM for TLS termination, WAF for filtering, and CloudFront for caching. The controller runs as an in-cluster deployment with an IRSA-bound IAM role granting `elasticloadbalancing:*` and related permissions.

Nginx Ingress, Traefik, and Istio Gateway are all viable K8s-native alternatives, but each terminates TLS inside the cluster and therefore would require cert-manager. This project's staged rollout — ACM in Phase 3, cert-manager in Phase 5 — means AWS Load Balancer Controller is the natural Phase 3 choice.

**GitOps bootstrap — ArgoCD via Terraform Helm, then self-managed via App-of-Apps.**

Terraform installs ArgoCD core via the official Helm chart. After the initial install, ArgoCD's `Application` CRD points at the `aegis-core` repository (per ADR-007) and ArgoCD self-manages all subsequent application deployments. Changes to ArgoCD's own configuration flow through the same GitOps path after bootstrap.

The `App-of-Apps` pattern organizes workload applications: a single root `Application` in this repo points to a directory in `aegis-core` that declares child applications. Adding a new workload is a commit to `aegis-core`, not a Terraform change here.

## Alternatives Considered

**Managed node groups instead of Karpenter.** Rejected. CLAUDE.md explicitly lists Karpenter as a Phase 3 learning goal. Managed node groups work but do not exercise dynamic binpack-based scaling, which is the interesting K8s autoscaling story for the portfolio. The two-year-old debate between Cluster Autoscaler and Karpenter is largely settled in Karpenter's favor for dynamic workload patterns — the portfolio should reflect current practice, not 2022 practice.

**Karpenter plus a small managed node group for system pods.** Considered. Keeps Karpenter simpler (it never needs to bootstrap itself) and provides guaranteed capacity for CoreDNS. Rejected in favor of Fargate because managed node groups have a minimum size of 1 node ($30/month for the smallest instance always-on) while Fargate bills per pod per second. For a lab with teardown after each session, Fargate wins on cost.

**Fargate for all workloads, no EC2.** Rejected. Fargate does not support DaemonSets or privileged pods, restricts volume types, and costs ~20% more per vCPU-hour than EC2. For the two-pod bootstrap (Karpenter + CoreDNS) it is ideal; for general workloads EC2 via Karpenter is cheaper and more flexible.

**Fully private EKS endpoint.** Rejected. Private-only requires a bastion host or SSM session manager for `kubectl` from the operator's laptop — adding infrastructure whose only purpose is reaching a cluster that is already behind an SSO-authenticated IAM role. The public endpoint is locked to the operator's IP via `public_access_cidrs` and secured by the cluster's IAM authentication. The actual attack surface is equivalent to a private endpoint plus bastion, without the bastion's operational cost and complexity.

**Pod Identity instead of IRSA.** Considered. EKS Pod Identity (2023) simplifies the IRSA token exchange and does not require the EKS OIDC provider to be externally trusted. For greenfield clusters it is the recommended approach, but the ecosystem documentation and operator tooling are still IRSA-dominant. This project uses IRSA for Phase 3 and tracks a Pod Identity migration for Phase 5 when service mesh integration might benefit from it.

**aws-auth ConfigMap for operator access.** Rejected. The ConfigMap is the legacy mechanism, deprecated by AWS in favor of Access Entries. New clusters should not use aws-auth unless there is a specific reason (e.g., existing tooling that reads it). There is none here.

**Docker Hub + NAT for public images, skip ECR.** Rejected. Docker Hub's unauthenticated rate limit (100 pulls per 6 hours per source IP) is easily exceeded by Karpenter provisioning five nodes in parallel, each pulling CoreDNS + aws-node + kube-proxy. Even the authenticated tier has a limit. ECR's $0.50/month storage cost is trivial compared to the operational risk of rate-limited image pulls during a demo.

**Let's Encrypt + cert-manager for all TLS.** Rejected for Phase 3, documented as Phase 5 work. See ADR-012 egress strategy and this ADR's TLS section — cert-manager earns its place when service mesh or in-cluster TLS termination creates actual requirements, not for a single ArgoCD UI cert that ACM handles for free.

## Consequences

EKS control plane costs $0.10/hour (~$73/month always-on) and is the largest single line item once the cluster is running. ADR-009's teardown discipline is load-bearing: sessions must end with `terraform destroy` of the `staging/platform` layer, or the monthly bill escalates.

Karpenter-provisioned EC2 instances use Spot by default (configurable per `NodePool`). Spot interruption is acceptable for lab workloads; any stateful workload that arrives later must explicitly opt in to on-demand via a dedicated `NodePool`.

The Fargate-hosted Karpenter pod is a small but continuous cost (~$30/month if left running). The teardown script must include Fargate profile removal. The `soft-teardown-workload.sh` per ADR-009 handles this automatically.

ECR repositories are created in `aegis-staging` by the `staging/platform/` Terraform layer. When the platform layer is destroyed, ECR repositories are preserved (`prevent_destroy = true` on the repository resource) so that image history survives cluster teardown. Only the cluster itself is ephemeral; artifacts persist.

The public EKS endpoint restricted to the operator's IP means the IP must be kept current in config. A mobile operator (different cafe, different VPN exit) either updates the config and re-applies the platform layer (~2 minutes) or falls back to SSM session manager through a bootstrap EC2 instance. Documented as a known operational trade-off of avoiding the bastion.
