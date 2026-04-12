# 002. Region and Availability Zone Strategy

## Status
Accepted

## Context
Every resource in an AWS account is region-scoped, with a small number of global exceptions such as IAM and Route 53. A landing zone must make a deliberate decision about which regions are allowed and how availability zones within those regions are referenced. Making these decisions implicitly — for example, by defaulting to whatever region the operator happened to log into — is a common antipattern that leads to shadow deployments, compliance violations, and cross-region latency surprises.

This ADR locks the region selection and the AZ referencing convention. It also documents a known limitation that will require future migration if the project's scope expands to cross-account networking.

## Decision

`eu-central-1` (Frankfurt) is the primary region. All baseline workloads — VPCs, EKS, ArgoCD, observability — deploy here by default.

`eu-west-1` (Ireland) is the disaster recovery region. It hosts CIDR reservations and can be used for a DR VPC, but does not run production workloads during normal operations. It exists so the design can extend to multi-region without rework later.

All other AWS regions are denied via Service Control Policies attached at the root OU level. The deny list applies to the `Workloads`, `Infrastructure`, and `Security` OUs. The management account is excluded from the deny to allow organization-level APIs that are always routed through `us-east-1`.

Availability zones are declared explicitly in `config/landing-zone.yaml` using AZ names such as `eu-central-1a`, `eu-central-1b`, and `eu-central-1c`. They are not discovered at runtime via `data "aws_availability_zones"`, and they are not declared as AZ IDs such as `euc1-az1`.

## Alternatives Considered

**`us-east-1` as the primary region.** Rejected. The operator is based in Germany, and GDPR data residency requirements make US regions inappropriate as a default for data handling. Additionally, `us-east-1` is the largest and noisiest AWS region, with a historically higher incident rate than `eu-central-1`.

**Auto-discover availability zones via `data "aws_availability_zones"`.** Rejected. This pattern is common in production Terraform modules, but it loses the explicitness of a declared AZ list. A config reviewer cannot tell at a glance which AZs will be used, and AZ selection becomes invisible in the config contract described in ADR-004. For a landing zone where every design choice must be portfolio-visible, explicit declaration wins over dynamic discovery.

**AZ IDs instead of AZ names.** Considered. AWS intentionally shuffles the mapping between AZ name (`eu-central-1a`) and physical AZ ID (`euc1-az1`) on a per-account basis, as a load-distribution mechanism. This means `eu-central-1a` in account A may correspond to a different physical zone than `eu-central-1a` in account B. For cross-account networking topologies such as PrivateLink, Transit Gateway attachments across accounts, or cross-account VPC peering, AZ IDs are the correct reference because they are stable.

This decision rejects AZ IDs for the current scope. Cross-account networking is explicitly out of scope per ADR-001, so the per-account shuffle is not a concern. AZ names are more readable in config review, which is a higher-priority concern at this project's scale. However, the decision is documented as a known limitation: if the project ever extends to cross-account networking, AZ declarations must migrate from names to IDs. The migration trigger is recorded below and in ADR-004.

**Single-region deployment with no DR region reservation.** Rejected. Even if DR is never exercised in the lab, reserving a second region in the allowed list and in the CIDR plan now means that future multi-region work is additive rather than a restructure. The cost of the reservation is zero; the cost of retrofitting multi-region support into a single-region codebase is substantial.

## Consequences

Every Terraform resource is region-aware. The region denial SCP catches any accidental deployment to a non-allowed region at the organization level, before the resource is created.

GDPR data residency is default, not an afterthought. A reviewer asking "where is user data stored?" gets a one-word answer: `eu-central-1` or `eu-west-1`, enforced by SCP rather than by convention.

The explicit AZ list in config means subnet layout is reviewable before `terraform apply`. A reviewer reading the config file sees that three AZs are used, which ones they are, and can cross-reference with the VPC CIDR plan in ADR-004.

The AZ-name limitation will require a one-time migration if scope expands to cross-account networking. The cost of that migration is bounded: replace AZ name references with AZ IDs in the config schema, update Terraform to resolve IDs via `data "aws_availability_zones" "available"` with `all_availability_zones = true`, re-run `terraform plan` to confirm no destructive changes, redeploy. The migration path is additive and does not destroy existing resources. This known limitation is an acceptable trade-off for present readability.

The region strategy is load-bearing for ADR-008: Control Tower's home region is permanent once selected, so the `eu-central-1` choice here cannot be revisited without decommissioning the landing zone.
