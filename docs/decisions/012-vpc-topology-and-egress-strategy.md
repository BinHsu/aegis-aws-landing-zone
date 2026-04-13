# 012. VPC Topology and Egress Strategy

## Status
Accepted

## Context
Phase 3 introduces the first workload VPC in `aegis-staging` to host an EKS cluster. Four decisions need to be locked before any network Terraform runs: subnet topology, CIDR allocation mechanism, egress strategy (NAT Gateway vs VPC endpoints vs hybrid), and VPC Flow Log handling.

Each decision has a cost dimension that matters for a lab project on a $30/month budget and a security dimension that matters for ISO 27001 Annex A compliance (ADR-005). Getting the egress strategy wrong either breaks ArgoCD's pull-based GitOps (no GitHub access from cluster) or burns money on VPC endpoints that duplicate what a single NAT Gateway would provide cheaper.

## Decision

**Subnet topology — three-AZ public/private split.**

The VPC spans three Availability Zones (`eu-central-1a`, `eu-central-1b`, `eu-central-1c` per ADR-002). Each AZ has one public subnet and one private subnet:

```
VPC 10.x.0.0/20 (from IPAM)
├── AZ-a
│   ├── Public  /24 — ALB, NAT Gateway
│   └── Private /23 — EKS nodes, workload pods
├── AZ-b
│   ├── Public  /24 — ALB, (no NAT)
│   └── Private /23 — EKS nodes, workload pods
└── AZ-c
    ├── Public  /24 — ALB, (no NAT)
    └── Private /23 — EKS nodes, workload pods
```

Public subnets host the ALB (multi-AZ required for ALB) and the single NAT Gateway. Private subnets host EKS nodes and all workload pods. The /23 sizing per AZ gives ~500 usable IPs per private subnet — ample for Karpenter-managed dynamic scaling without forcing a resize later.

**CIDR allocation — IPAM (ADR-004 Mode B).**

VPC CIDR is allocated from the regional IPAM pool declared in `config/landing-zone.yaml` (`ipam.pools.eu-central-1`). The staging VPC requests `netmask_length: 20` from IPAM, which assigns the first available /20 block. IPAM enforces non-overlap across all VPCs in the organization — no human CIDR planning, no accidental conflicts when adding future accounts.

**Egress strategy — hybrid: one NAT Gateway + Gateway endpoints, no Interface endpoints.**

```
Internet-bound traffic  → NAT Gateway (1, in AZ-a) → IGW → Internet
S3 and DynamoDB traffic → Gateway VPC Endpoint (free) → AWS backbone
Other AWS services      → NAT Gateway → public AWS endpoints
```

The cluster needs internet egress for three specific external dependencies:
- **GitHub.com** — ArgoCD pulls application manifests from `aegis-core` repository (pull-based GitOps per ADR-007).
- **Public Helm repositories** — initial installation of ArgoCD, Karpenter, and AWS Load Balancer Controller charts.
- **Public container registries** (rare) — if any workload explicitly pulls from a non-AWS registry. Default is to mirror everything to ECR (ADR-013).

All three are non-AWS destinations that VPC endpoints cannot reach. NAT Gateway is the only mechanism that satisfies them. One NAT (not three) is sufficient because lab workloads tolerate an AZ-a outage reducing the cluster to degraded egress; production deployments should run three NATs for AZ-independent egress.

Gateway endpoints for S3 and DynamoDB are included because they are **free**. S3 is the largest traffic source in any EKS cluster — container image layers from ECR traverse S3 internally — and routing S3 traffic through the Gateway endpoint avoids NAT data processing fees entirely ($0.045/GB saved on every image pull). DynamoDB is not used today but the endpoint costs nothing to provision and eliminates a future migration when state-aware services arrive.

Interface VPC endpoints (ECR API, STS, EKS, SSM, CloudWatch Logs, EC2) are **not** provisioned. At $0.01/hour per endpoint per AZ, six endpoints in three AZs cost $131/month — more than three NAT Gateways. For a single-NAT lab topology the per-session cost of NAT data transfer is pennies and far cheaper than interface endpoints.

**VPC Flow Logs — to logarchive account.**

VPC Flow Logs capture all accepted and rejected traffic at the VPC level and ship to an S3 bucket in `aegis-logarchive` (the centralized log archive per ADR-006). The log format includes source/destination IP, port, protocol, action, bytes, and AWS account ID. Retention is 90 days in the logarchive bucket. Flow Logs satisfy ISO 27001 Annex A.8.15 (Logging) for network-layer events and feed future Security Hub / GuardDuty analysis.

## Alternatives Considered

**Pure PrivateLink topology — no NAT Gateway at all.** Rejected. Eliminating NAT requires eliminating all non-AWS outbound destinations, which means mirroring every external dependency: GitHub source to CodeCommit, public Helm charts to ECR, public container images to ECR, Let's Encrypt to ACM. This is technically feasible but defeats the portfolio narrative of GitHub-centric pull-based GitOps. The architectural story changes from "standard K8s GitOps on AWS" to "air-gapped AWS with mirror infrastructure" — a different demonstration with different audiences. This project optimizes for the standard-GitOps story.

**Three NAT Gateways for AZ-independent egress.** Rejected for this lab project. Cost is $97/month always-on (three NATs × $32) versus $32 for a single NAT, for redundancy that lab workloads do not require. Teardown discipline (ADR-009) means NATs run for at most ~4 hours per session, so per-session cost is $0.54 vs $0.18 — pennies either way. But the "always-on" distinction matters if the operator forgets to tear down. The single-NAT choice is documented as a lab-specific compromise; production deployments must use one NAT per AZ.

**Full Interface VPC endpoint coverage for all AWS services.** Rejected. The calculation is $0.01/hr × 6 endpoints × 3 AZs = $0.18/hr = $131/month always-on, exceeding even the three-NAT configuration. Per-session cost ($0.72 for a four-hour session) is higher than NAT ($0.18). Interface endpoints make sense for enterprise environments with sustained traffic where the hourly cost is amortized across heavy utilization, not for a lab that runs a few hours at a time.

**Two NAT Gateways in different AZs as a compromise.** Considered and rejected. Two NATs is a weird middle ground: it costs two-thirds of the HA price but still leaves one AZ without NAT. The operational model is either "single NAT, lab accepts degraded-AZ impact" or "one NAT per AZ, production-grade resilience." There is no coherent story for two.

**Single-AZ VPC (one public + one private subnet only).** Rejected. EKS requires subnets in at least two AZs for control plane resilience. Additionally, AWS Load Balancer Controller requires multi-AZ subnets to create an internet-facing ALB. Single-AZ is simply non-functional for the target workload.

**Four-AZ topology** (eu-central-1 has four AZs). Rejected as over-scope. Three AZs match ADR-002's declared zones and provide K8s-recommended HA. Adding a fourth AZ increases subnet count and IP waste without meaningful resilience improvement at current scale.

## Consequences

VPC Flow Logs produce ~$0.50/GB/month of log storage — small volume at lab scale, but a nonzero line item in the monthly bill. The logarchive bucket has lifecycle rules to transition logs to Glacier after 30 days if cost becomes a concern.

The single NAT Gateway creates a regional single point of failure. If AZ-a suffers an outage, all cluster egress to the internet stops. Private subnet → AWS services (via regional AWS backbone) and Gateway endpoints (S3, DynamoDB) continue working. This is explicitly accepted for the lab environment and explicitly documented as not acceptable for production.

IPAM allocation couples the staging VPC to the shared/ipam Terraservices layer. VPC creation requires `shared/ipam/` to be applied first. This ordering is documented in the runbook and enforced by Terraform's `terraform_remote_state` data source reading the IPAM pool ID from the `shared/ipam` state.

Future workload accounts (`aegis-prod`, future sandboxes) follow the same topology — three-AZ public/private, single NAT, Gateway endpoints, IPAM-allocated CIDR. A Terraform module at `terraform/modules/vpc/` extracts the pattern once there are two or more consumers (DRY triggered by actual reuse, not anticipation).

The absence of Interface endpoints means every non-S3, non-DynamoDB AWS API call traverses NAT. For services like STS (IRSA token exchange, every pod every hour) and CloudWatch Logs (every log line), this is a measurable data volume. At lab scale the total is well under a dollar per session. At production scale, this is the trigger to add Interface endpoints — but only for the specific high-traffic services, not a blanket deployment.
