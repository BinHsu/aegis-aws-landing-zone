# 008. Landing Zone Tooling — Control Tower plus Terraform Hybrid

## Status
Accepted

## Context
In 2026, a newly-provisioned AWS landing zone has three reasonable tooling paths: fully hand-rolled via Terraform (or CloudFormation), fully managed via AWS Control Tower, or a hybrid that uses Control Tower as a managed foundation and extends it with custom Terraform for everything Control Tower does not cover. A fourth path — AWS Landing Zone Accelerator (LZA) — is essentially the hybrid path with AWS CDK as the extension language instead of Terraform.

The choice among these paths is the most load-bearing decision in the project. It determines what code exists in the repository, what capabilities are automatic versus hand-configured, how fast the project reaches Phase 2 where the actual learning gaps live, and what interview narrative the portfolio can support. This ADR documents the choice, the reasoning, and the trade-offs.

## Decision

Use AWS Control Tower as the managed foundation, and extend it with custom Terraform for everything not covered by Control Tower defaults.

**Control Tower handles:** initial landing zone enrollment, OU structure defaults, automatic creation of `Audit` and `Log Archive` accounts (mapped to `aegis-security` and `aegis-logarchive` per ADR-006), baseline preventive and detective guardrails, organizational CloudTrail, AWS Config baseline, and AWS Identity Center bootstrap.

**Terraform handles:** creation of the `aegis-shared` account via Account Factory for Terraform, creation of the `aegis-staging` and `aegis-prod` accounts via the same mechanism, custom SCPs beyond Control Tower defaults, the GitHub OIDC identity provider, IAM roles for CI/CD, VPCs, EKS, ArgoCD and other platform components, observability stack, workload resources, and everything else that is portfolio-visible.

The Control Tower home region is `eu-central-1` per ADR-002 and is permanent once set. The decision is intertwined with the region strategy and cannot be revisited without decommissioning the landing zone.

## Alternatives Considered

**Pure hand-rolled Terraform, no Control Tower.** Rejected. The operator has five years of direct AWS Organizations operational experience from prior roles. Hand-rolling `aws_organizations_organization`, OU definitions, and baseline SCPs from scratch provides essentially no learning value — it is rewriting something already known — and consumes two to four weeks of project time that should instead be spent on the genuine learning gaps: GitHub Actions (replacing Jenkins background), ArgoCD (replacing push-based CD), GitHub OIDC federation, Go, and Karpenter. None of those learning goals are affected by whether Control Tower is used.

The interview narrative also suffers under the hand-rolled path. A candidate with five years of Organizations experience who chose to hand-roll it looks like they could not find more valuable uses of the time. The hybrid answer — "I used Control Tower for the foundation because reinventing Organizations provides no learning value for me, and I used Terraform for the layers where my actual learning gap is" — is a senior-level decision-making statement that treats time as a scarce resource and allocates it consciously.

**AWS Landing Zone Accelerator (LZA).** Rejected. LZA is the most feature-complete managed landing zone offering from AWS and extends Control Tower with declarative customizations. It is implemented in AWS CDK, which would introduce a second infrastructure-as-code language into the project and split attention between Terraform and CDK idioms. For a project whose primary learning goal within infrastructure-as-code is vanilla Terraform, adding CDK is counterproductive — it fragments the skill being demonstrated.

**Control Tower alone, no Terraform extensions.** Rejected. Control Tower by itself provisions the landing zone foundation but does not create application infrastructure — no VPCs, no EKS, no OIDC, no IAM for workloads, no observability. A portfolio project needs all of that visible in the repository as infrastructure-as-code. Control Tower alone leaves nothing for a reviewer to read.

**Third-party landing zone products such as Gruntwork Reference Architecture.** Rejected. These introduce vendor dependencies and proprietary abstractions that do not serve the learning goals. The project explicitly uses only AWS first-party services and open tooling so that the learning transfers to any AWS environment.

**Customizations for Control Tower (CfCT) for the Terraform-extension layer.** Considered. CfCT is the AWS-native mechanism for extending Control Tower with custom configurations via CloudFormation StackSets. It is a valid path, but it forces CloudFormation as the extension language, which fragments the IaC skill set in the same way CDK does. Terraform as the extension language is cleaner.

## Consequences

Direct use of `aws_organizations_account` for the Security OU is impossible — those accounts are created by Control Tower, not Terraform. Workload accounts (`aegis-shared`, `aegis-staging`, `aegis-prod`) must be provisioned via Account Factory for Terraform, not Terraform directly. This is an accepted constraint and documented in ADR-006.

Some OU names and baseline guardrails are locked by Control Tower defaults and cannot be removed, only supplemented. Custom SCPs and guardrails layer on top of the defaults. The cost of this constraint is small because the defaults are already well-designed for the project's needs.

Config recorder runs continuously in all enrolled accounts, adding approximately five dollars per month of baseline cost. See ADR-009 for the full cost model.

Control Tower's home region is permanent. Changing it requires decommissioning the landing zone, which is a destructive operation subject to the constraints documented in ADR-009. The region selection in ADR-002 is therefore load-bearing for this decision and cannot be revisited casually.

Time-to-Phase-2 is reduced from weeks to hours. Phase 1 (foundation) is substantially automated by Control Tower, which frees the project to spend its time on the phases where actual learning occurs. This is the most important consequence: the project's finite time budget is allocated to the parts that produce portfolio value, not to the parts that rebuild something already known.

The interview narrative becomes offensive rather than defensive. A reviewer asking "why did you use Control Tower?" receives the answer above; a reviewer asking "why didn't you use Control Tower?" receives the same answer. Both framings are addressed by the same ADR, which is the mark of a decision that has been genuinely considered.
