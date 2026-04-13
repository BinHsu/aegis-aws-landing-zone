# 004. Deployment Configuration Contract

## Status
Accepted

## Context
A landing zone that cannot be rebuilt from a single config file is not a landing zone — it is an artifact of one person's AWS console clicks. The reproducibility requirement in ADR-001 states that any user with AWS credentials and a filled config file must be able to deploy the entire landing zone end-to-end. This ADR specifies the mechanism: a single externalized YAML configuration file that every Terraform module reads, with no hardcoded identifiers anywhere in committed code.

The config file is the contract. If the contract is clean, fork-and-deploy is a config-only operation. If the contract is leaky, reproducibility degrades silently until the next operator discovers a hardcoded region name three layers deep in a module.

## Decision

All deployment-specific values live in `config/landing-zone.yaml`. This file is listed in `.gitignore` and never committed. A sibling file `config/landing-zone.example.yaml` is committed with placeholder values and serves as a template for forks. A JSON Schema at `config/schema.json` validates the config before any Terraform operation, enforced by a pre-commit hook.

Terraform reads the config via `locals { config = yamldecode(file("${path.root}/../../../config/landing-zone.yaml")) }` at the top of every environment. No Terraform module references a hardcoded email, account ID, region, or CIDR.

The schema contains:

- **Organization metadata**: organization name (`aegis`), email domain (`binhsu.org`), child account email pattern (`aws-aegis-{account}@binhsu.org`).
- **Accounts list**: each entry has `name`, `ou` placement, and a `vpcs` map keyed by region containing `netmask_length` and `ipam_pool` reference.
- **Regions list**: each entry has `name`, `role` (primary or dr), and an explicit `zones` list of AZ names.
- **GitHub references**: org name, infra repo name, app repo name.
- **Tagging taxonomy**: required tags `Project`, `Environment`, `ManagedBy`, `CostCenter`, `Owner`, `DataClassification`, `Compliance`.
- **Budget**: daily USD ceiling, alert email.
- **IPAM pool declarations**: top CIDR and per-region pool configurations.

**Email strategy — Scheme P1, root-scoped.** All six AWS account root emails use the pattern `aws-aegis-{account}@binhsu.org`, producing addresses such as `aws-aegis-management@binhsu.org`, `aws-aegis-security@binhsu.org`, `aws-aegis-shared@binhsu.org`, `aws-aegis-staging@binhsu.org`, and `aws-aegis-prod@binhsu.org`. Mail is delivered via Cloudflare Email Routing catch-all to the operator's personal inbox. The `binhsu.org` domain is registered through Cloudflare Registrar, with DNS, email routing, and registrar consolidated under a single Cloudflare console.

**CIDR management — Mode B, AWS IPAM-driven.** IPAM pools are themselves Terraform-managed in the `aegis-shared/bootstrap` layer described in ADR-003. Each VPC declaration in config specifies `netmask_length` and an `ipam_pool` reference; IPAM performs the actual allocation, enforcing non-overlap at the AWS API level rather than relying on human CIDR planning.

## Alternatives Considered

**`terraform.tfvars` as the config contract.** Rejected. Only Terraform can read `.tfvars` files, which excludes scripts, GitHub Actions workflows, and any future Go or Python tooling from the same contract. YAML can be read by every language and every tool.

**Environment variables.** Rejected. Environment variables handle scalar values reasonably but are miserable for nested structures such as the accounts-with-VPCs hierarchy. No schema validation is possible without reinventing the mechanism.

**Hardcoded values in `.tf` files.** Rejected. Violates the reproducibility requirement in ADR-001, leaks PII (email addresses) into a public repository, and prevents fork-and-deploy.

**Gmail plus-addressing for account emails.** Rejected. Creates a single point of failure on one Gmail inbox — compromise of the inbox cascades to all six AWS accounts via root password recovery. Segregation-of-duties compliance stories become untenable because there is only one human owner. The visual weakness in portfolio code review is real: `pcpunkhades+aegis-prod@gmail.com` signals personal lab, while `aws-aegis-prod@binhsu.org` signals a designed naming contract.

**Subdomain-scoped email namespace (Scheme P2).** Considered. Scheme P2 would use `aws-{account}@aegis.binhsu.org`, isolating each project's email namespace under a subdomain and enabling clean project handoff by delegating the subdomain. This is marginally cleaner for multi-project portfolio evolution but requires additional Cloudflare Email Routing configuration per subdomain. Scheme P1 was chosen for minimal setup complexity; migration to P2 remains possible as a future refactor.

**Mode A static CIDR allocation.** Rejected. Hand-planned `10.<region>.<account>/prefix` schemes work fine at current scale but shift the non-overlap burden onto humans. IPAM enforces it at the API level and scales to arbitrary account counts without human error.

## Consequences

Every Terraform module must consume from `local.config` and never hardcode values. Reviewers can grep for hardcoded account IDs or region names as an antipattern.

Fork-and-deploy becomes a config-only operation. A hiring manager reviewing the repo can see exactly what would change to deploy this landing zone into their own AWS organization: one file.

The JSON Schema must be kept in sync with Terraform code as the contract evolves. Schema drift is caught by the pre-commit hook before a commit can land.

IPAM introduces a small ongoing cost (approximately one to five dollars per month) and a destroy-ordering complexity: VPC allocations must be freed before IPAM pools can be deleted. The `soft-teardown-workload.sh` script in ADR-009 handles this ordering explicitly.

Scheme P1 root-scoped emails mean a future migration to subdomain scheme would require AWS root-email-change operations on each account, which are supported but require verification through the old email. This is documented as a known trade-off.

### Design gap discovered during implementation (Incident 7)

The original decision text described IPAM in `aegis-shared` with RAM cross-account sharing, but did not enumerate the full set of prerequisites needed to make cross-account CIDR allocation work. Two independent org-level mechanisms are required, not one:

1. **RAM sharing enablement** (`aws_ram_sharing_with_organization`) — lets member accounts *see and consume* the IPAM pool.
2. **IPAM trusted service access + delegated administrator** — lets the IPAM service *monitor* member accounts so `AllocateIpamPoolCidr` API calls from member accounts succeed.

The mental model we used at ADR time ("bucket-policy-plus-PrincipalOrgID is how cross-account works in AWS") did not extend to IPAM, which has its own service-level integration model. RAM visibility ≠ IPAM allocation permission. Discovered the hard way at [Incident 7](../incidents.md#incident-7--ipam-delegated-admin-not-configured-for-cross-account-vpc-allocation).

The lesson generalizes: every AWS multi-account service has its own "org integration" pattern (enable trusted service access, delegate admin, configure service-linked roles). RAM, IPAM, GuardDuty, Security Hub, Config, Macie all have this pattern, and each has subtle differences. Future ADRs that span accounts should explicitly enumerate the org-level prerequisites, not assume them.
