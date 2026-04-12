# 003. Terraform Backend Bootstrap and State Layout

## Status
Accepted

## Context
Every Terraform project requires a state backend. Every multi-account landing zone faces the same question twice: where does the state live, and how is it organized? The state backend itself has a chicken-and-egg problem — it must be created before Terraform can use it — and the state layout determines the blast radius of every future `terraform apply`. Getting both decisions right is cheap; getting them wrong is among the most painful refactors in infrastructure-as-code, because state migration is manual, error-prone, and blocks all parallel development during the migration window.

This ADR locks both decisions for the `aegis-aws-landing-zone` project.

## Decision

Terraform state is stored in S3 with native locking (`use_lockfile = true`), not DynamoDB. Native S3 locking became generally available in Terraform 1.10 and removes an entire managed service from the architecture, reducing operational surface and cost.

The state bucket lives in the `aegis-shared` account — a dedicated shared-services account in the Infrastructure OU described in ADR-006. It does not live in the management account, which is reserved for Organizations, SCPs, Identity Center, and Billing per the management account boundary in ADR-001.

State layout follows the Terraservices pattern, popularized by Nicki Watt and Charity Majors at HashiConf 2016 and documented in Yevgeniy Brikman's "Terraform: Up & Running". Each account has multiple state files split by layer:

- `bootstrap` — account-level baseline: IAM identity providers, KMS keys, budget alarms, basic tag enforcement.
- `network` — VPC, subnets, route tables, NAT gateways, Transit Gateway attachments.
- `platform` — EKS cluster, Karpenter, ArgoCD installation, cert-manager, Kyverno.
- `workloads` — application-specific resources layered on top of the platform.

State keys in S3 follow the pattern `<account>/<layer>/terraform.tfstate`, producing paths like `staging/network/terraform.tfstate` and `prod/platform/terraform.tfstate`. The `aegis-shared/bootstrap/terraform.tfstate` state is a special case: it includes the S3 bucket that hosts every other state file.

The bootstrap sequence for the state bucket itself uses local state first. The initial `terraform apply` runs with `backend "local"` to create the S3 bucket and related resources. The `backend.tf` is then updated to point at S3, and `terraform init -migrate-state` moves the state from the local file into the new bucket. This is a one-time operation documented in a repository runbook.

## Alternatives Considered

**DynamoDB for state locking.** Rejected. DynamoDB-based locking was the standard pattern before Terraform 1.10 but now adds an additional managed service, an additional IAM policy surface, and a small ongoing cost — all for a capability S3 now provides natively. Removing DynamoDB simplifies the architecture without losing any functionality.

**State in the management account.** Rejected. Hosting state in the management account would violate the boundary in ADR-001 and is a well-known antipattern in AWS landing zone guidance. The management account must remain minimal so that its blast radius stays minimal.

**One monolithic state file per environment.** Rejected. Monolithic state has the worst possible blast radius: any `terraform apply` touches the entire environment, and any state corruption breaks every component simultaneously. Parallel development becomes impossible because only one operator can `apply` at a time.

**Terragrunt as a wrapper over Terraform.** Rejected. Terragrunt is widely used in the industry and provides genuine value for large organizations with dozens of environments. For this project, the learning goal is vanilla Terraform — adding a wrapper language muddies the interview narrative and creates an additional tool to master before the underlying tool is fully understood. Terragrunt is documented as a future evolution path.

**OpenTofu Stacks.** Rejected. OpenTofu introduced Stacks as a layering abstraction in 2025, but the feature is too new and its ecosystem is insufficient to stake a portfolio project on it. This decision may be revisited as OpenTofu matures.

## Consequences

Each Terraservices layer is independently `plan`/`apply`/`destroy`-able. This is the property that makes selective teardown possible in ADR-009. Destroying the `platform` layer to clean up an EKS cluster after a session is a routine operation that does not touch `bootstrap` or `network`.

Cross-layer dependencies are explicit. The `platform` layer reads outputs from the `network` layer via `data "terraform_remote_state"`, which forces a review of every boundary crossing. There is no implicit shared state.

The one-time bootstrap of the state bucket is a minor operational cost, documented as a runbook. After the first `terraform init -migrate-state`, the operation is never repeated.

Adding a new layer — for example, a future `data` layer for RDS and backups — is additive. Existing layers are untouched. The state key convention gives every new layer an obvious place to live.

The choice of S3 native locking means Terraform version 1.10 or later is a hard dependency. This is documented in the repository README and enforced by a `.terraform-version` file consumed by `tenv` or `tfenv`.

The Terraform backend configuration block does not support variables or locals — this is a Terraform language limitation, not a design choice. The S3 backend block in each environment therefore contains a hardcoded bucket name and region. This is the only place in the project where values are hardcoded rather than read from `config/landing-zone.yaml`, and it is an accepted trade-off documented inline.

### Future Hardening

The following items are deliberately deferred from the initial state bucket deployment. Each is documented here so that future operators know they were considered and consciously deferred, not overlooked.

**S3 access logging.** The state bucket does not currently have S3 server access logging enabled. ISO 27001:2022 Annex A.8.15 (Logging) recommends access logging on critical storage. Enabling it requires a dedicated log-destination bucket with ACL-based write permissions (S3 access logs cannot use bucket policies). This is a Phase 2 hardening item — the state bucket should be functional before adding observability on top of it.

**Per-layer state isolation.** The current bucket policy grants read/write access to any principal in the AWS Organization via `aws:PrincipalOrgID`. This means a role in the staging account can theoretically read or write the production state file. For a single-operator lab project this is acceptable. When multiple teams or operators are introduced, the bucket policy should be tightened with IAM path conditions or S3 prefix-scoped policies to enforce per-account or per-layer access boundaries.

**Cross-region state replication.** The state bucket exists in a single region (`eu-central-1`) with no cross-region replication. State file loss in a regional outage would require reconstruction from AWS resource inspection. For a lab project the risk is acceptable. Production deployments should enable S3 Cross-Region Replication to the DR region (`eu-west-1`) with a dedicated replica bucket.
