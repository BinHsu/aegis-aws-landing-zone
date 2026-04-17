# 017. Workload Namespace and RBAC Model

## Status
Accepted

## Context

Phase 4a' delivers the "docking station" — the platform-side infrastructure that aegis-core workloads will deploy into. Before writing any Terraform, three questions need answers:

1. **Namespace topology**: Should aegis-core's gateway and engine run in one shared namespace or separate namespaces?
2. **Namespace lifecycle owner**: Should Terraform create the namespace, or should ArgoCD create it on first sync?
3. **RBAC model**: What Kubernetes RBAC (beyond the existing cluster-admin for the operator) does the workload namespace need?

The answers affect NetworkPolicy scope, IRSA trust policies, ArgoCD sync permissions, and the blast radius of a misconfigured workload.

### Constraints

- **Single operator, single application**: aegis-core is the only workload. There is no multi-tenancy requirement.
- **ArgoCD auto-sync for staging**: CLAUDE.md mandates auto-sync for staging. The root Application in `argocd.tf` already sets `automated.prune = true` and `automated.selfHeal = true`.
- **IRSA per-ServiceAccount scoping**: each IRSA role is bound to exactly one `namespace:serviceaccount` pair. Fewer namespaces means fewer IRSA roles to manage.
- **NetworkPolicy is namespace-scoped**: a default-deny NetworkPolicy applies to the namespace it lives in. Per-component namespaces would require coordinating NetworkPolicies across namespace boundaries for gateway↔engine communication.
- **Cost**: $0 — namespaces and RBAC objects are Kubernetes API resources with no AWS billing.

## Decision

### Single `aegis` namespace for all aegis-core workloads

Gateway and engine pods share a single `aegis` namespace. This is appropriate because:

- They are components of one application, not independent services. aegis-core's ADR-0017 describes the gateway as a gRPC client of the engine — they are co-designed and co-released.
- A single namespace means gateway↔engine NetworkPolicy is an intra-namespace allow rule, not a cross-namespace rule. Simpler to write, easier to audit.
- IRSA trust policies scope to `system:serviceaccount:aegis:<sa-name>`. Adding a second ServiceAccount in the same namespace is a one-line change; adding a second namespace requires a new IRSA role with a new trust policy.
- ArgoCD's root Application already uses `CreateNamespace=true` as a sync option, but workload-specific resources target the `aegis` namespace via their manifests, not via ArgoCD creating it ad hoc.

### Terraform creates the namespace; ArgoCD deploys into it

The `aegis` namespace is created by Terraform in the `staging/workloads` layer, not by ArgoCD's `CreateNamespace=true` sync option. Reasons:

- **Platform-side resources depend on the namespace existing**: IRSA skeleton roles reference the namespace in their trust policy subject (`system:serviceaccount:aegis:*`). The default-deny NetworkPolicy lives in the namespace. These are Terraform-managed resources that must exist before any workload syncs.
- **Terraform owns the contract; ArgoCD owns the contents**: the namespace, IRSA roles, and NetworkPolicy base are part of the platform surface contract ([#54](https://github.com/BinHsu/aegis-aws-landing-zone/issues/54)). Workload Deployments, Services, and Ingresses are aegis-core's concern, synced by ArgoCD.
- **Teardown ordering**: `terraform destroy` of the workloads layer can clean up the namespace and its dependent IAM roles in one pass. If ArgoCD owned the namespace, teardown would require sequencing ArgoCD app deletion before Terraform destroy — adding the kind of ordering dependency that caused Incidents 20 and 22.

### No namespace-scoped RBAC for Phase 4

The existing `aegis-cluster-admins` group (bound to `cluster-admin` ClusterRole via `cluster-role-binding.tf`) is sufficient for a single-operator lab. Adding namespace-scoped Roles and RoleBindings would be RBAC machinery with no consumer — the only human principal already has cluster-admin, and pod-level access is governed by IRSA, not RBAC.

If multi-tenancy or a second operator arrives (not planned — see `docs/phase4.md` §What is NOT Phase 4), RBAC scoping becomes a real requirement and should get its own ADR at that point.

## Alternatives Considered

**Per-component namespaces (`aegis-gateway`, `aegis-engine`).** Rejected. Adds operational overhead without security benefit in a single-application, single-operator context. Cross-namespace communication requires explicit NetworkPolicy allow rules on both sides, doubles the IRSA role count, and splits ArgoCD sync targets. The Kubernetes best practice of "namespace per team" does not apply when there is one team.

**ArgoCD creates the namespace via `CreateNamespace=true`.** Rejected. ArgoCD's `CreateNamespace=true` is a convenience for application namespaces that have no platform-side dependencies. The `aegis` namespace has Terraform-managed IRSA roles and NetworkPolicies that must exist before the first workload sync. Letting ArgoCD create the namespace would either (a) race with Terraform, or (b) require Terraform to import the ArgoCD-created namespace — both fragile.

**Namespace-scoped RBAC with dedicated ServiceAccounts for CI and operator.** Deferred. Valid for production multi-tenancy but premature for this lab. The operator has cluster-admin; CI has cluster-admin via Access Entries. Adding namespace-scoped bindings would be defense-in-depth with no threat model to defend against — the only principals are the operator and CI, both already trusted at the cluster level.

## Consequences

The `staging/workloads` layer creates the `aegis` namespace and is the owner of its lifecycle. Any future workload layer changes (adding a second namespace, tightening RBAC) are Terraform changes in this layer, not ArgoCD manifest changes.

The platform surface contract ([#54](https://github.com/BinHsu/aegis-aws-landing-zone/issues/54)) must be updated to document the `aegis` namespace as the deployment target for aegis-core workloads.

ArgoCD's root Application (in `argocd.tf`) continues to point at `apps/staging/` in aegis-core. Aegis-core manifests must target `namespace: aegis` in their Deployment/Service/Ingress metadata. If they target a different namespace, ArgoCD will create it (due to `CreateNamespace=true`) — but that namespace will lack IRSA and NetworkPolicy. This is an intentional fail-safe: workloads landing outside `aegis` will not have AWS permissions, making the misconfiguration visible immediately rather than silently permissive.
