# 012. IPAM and Org-Wide CIDR Allocation

## Status
Accepted

> **Amended 2026-05-18 — ADR-033 account-fabric descope.** This ADR originally
> specified the full staging VPC topology: three-AZ subnet split, single-NAT
> egress, Gateway endpoints, and VPC Flow Logs. Those are workload networking
> concerns and moved to the Platform tier together with the `staging/network`
> layer (see ADR-033). What remains — and what the account fabric still owns —
> is AWS IPAM: the single organization-wide authority that allocates
> non-overlapping VPC CIDRs to every account and every Platform-tier consumer.
> The ADR was retitled and trimmed to that surface; the original VPC-topology
> text is preserved in the `v1.0.0` git tag.

## Context

Every VPC needs a CIDR block, and CIDR blocks must not overlap — overlapping
ranges break VPC peering, Transit Gateway routing, and any future
cross-account connectivity. In a multi-account organization with more than one
team — or, here, more than one sibling repository provisioning VPCs — "pick a
/20 and hope nobody else picked the same one" does not scale. Some authority
has to own the address plan.

That authority is an account-fabric concern, not a workload concern: it must
be a single, organization-wide registry, defined once and consumed everywhere
— structurally the same kind of guardrail as an SCP or the OU layout. A VPC
*consumes* an allocation; it does not *arbitrate* one.

## Decision

A single **AWS IPAM** instance, provisioned by the `shared/ipam` Terraservice
layer in the `aegis-shared` account, owns all VPC CIDR allocation for the
organization.

**Hierarchy** (private scope):

```
IPAM (advanced tier — required for cross-account RAM sharing)
└── Top-level pool — 10.0.0.0/8 (entire RFC1918 10/8 space)
      ├── Regional pool eu-central-1 — 10.0.0.0/12   ┐ shared org-wide
      └── Regional pool eu-west-1    — 10.16.0.0/12  ┘ via AWS RAM
```

Top-level and regional pool CIDRs are declared in `config/landing-zone.yaml`
(`ipam.top_cidr`, `ipam.pools.<region>.cidr`) — adding a region is a config
edit, no `.tf` change.

**Cross-account sharing via RAM.** The regional pools are shared to the whole
organization through an AWS Resource Access Manager share
(`aws_ram_resource_share` + `aws_ram_principal_association` on the org ARN).
Without the share, only `aegis-shared` could draw from the pools; with it, any
member account — and any Platform-tier repository operating in those accounts
— can allocate a CIDR.

**Allocation is pull, not declare.** A consumer VPC sets `ipv4_ipam_pool_id` +
`ipv4_netmask_length` instead of a literal `cidr_block`. IPAM picks an unused
block of the requested size and enforces non-overlap at the API level — the
allocated CIDR is known-after-apply. No operator ever types a `10.x` number;
collision is structurally impossible.

**Cost.** IPAM advanced tier bills $0.0027/IP/hour for IPs that IPAM actively
manages. Idle pools cost $0. A /20 VPC running 24/7 is ~$8/month; a four-hour
session is ~$0.04.

## Alternatives Considered

**Manual CIDR planning in a spreadsheet / config file.** Rejected. Works for a
single operator on day one; fails the moment a second VPC — or a second
sibling repository — allocates without consulting the spreadsheet. The whole
point of an account fabric is to remove that class of coordination error.

**IPAM owned by a Platform-tier repository.** Rejected. If the IPAM lived in
one Platform repo (e.g. the EKS platform repo), every *other* Platform repo
would have to cross-depend on it for address space — re-coupling the tiers
that ADR-033 separates. And if each Platform repo ran its own IPAM, there
would be no central non-overlap arbiter and collisions return. A single
org-wide IPAM in the account fabric is the only layout where every consumer,
present and future, draws from one collision-free authority.

**IPAM free tier (no advanced tier).** Rejected. The free tier does not
support cross-account RAM sharing of pools, which is the entire mechanism that
lets member accounts allocate. Advanced tier is mandatory for the design; the
cost is negligible at lab scale.

## Consequences

The `shared/ipam` layer is a baseline-tier dependency of every VPC in the
organization. Any Platform-tier `network` layer must read the RAM-shared pool
(by `data` lookup, or by reading `shared/ipam` remote state) before it can
create a VPC. This is a deliberate, one-directional dependency: account fabric
→ Platform tier, never the reverse.

The account fabric provisions IPAM but operates no VPC itself — it is a
provider of address space, not a consumer, exactly as it provisions OUs and
SCPs without running workloads in them.

Adding a region is a `config/landing-zone.yaml` edit (`regions[]` plus
`ipam.pools.<region>`); IPAM gains a regional pool and a RAM association with
no `.tf` change.
