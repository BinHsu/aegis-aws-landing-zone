# AWS Landing Zone Lab

> Production-grade multi-account AWS landing zone with GitOps, built from scratch as a hands-on portfolio project.

## Purpose

Demonstrate end-to-end ability to design and build enterprise AWS infrastructure from zero:
- Multi-account AWS Organizations with OUs and SCPs
- AWS Identity Center (SSO) with role-based access
- GitHub OIDC federation (zero static credentials)
- Terraform IaC with S3 backend + native locking
- GitHub Actions CI/CD (plan on PR, apply on merge)
- EKS cluster with ArgoCD GitOps
- Observability (Prometheus + Grafana)
- Security baseline (CloudTrail, Config, GuardDuty)

## Architecture

```
AWS Organizations (Management Account)
├── OU: Security
│   └── Security Account (CloudTrail aggregation, GuardDuty, Config)
├── OU: Workloads-Prod
│   └── Production Account (EKS, RDS, application workloads)
├── OU: Workloads-Staging
│   └── Staging Account (EKS, testing)
└── SCPs: region restriction, security guardrails

GitHub (OIDC → AWS)
├── terraform/          → GitHub Actions: plan/apply
├── k8s-manifests/      → ArgoCD watches and syncs
└── .github/workflows/  → CI/CD pipeline definitions

EKS Cluster
├── ArgoCD (GitOps controller)
├── Prometheus + Grafana (observability)
├── cert-manager (TLS)
└── Application workloads
```

## Phases

| Phase | Scope | Cost | Status |
|-------|-------|------|--------|
| 1. AWS Foundation | Organizations, OUs, SCPs, SSO, Terraform backend, GitHub OIDC | ~Free | Not started |
| 2. GitOps Pipeline | Terraform repos, GitHub Actions workflows, plan/apply automation | ~Free | Not started |
| 3. EKS + ArgoCD + Karpenter | EKS cluster, ArgoCD, **Karpenter (Dynamic Node Autoscaling)**, GitOps deployments | ~$5-10/session | Not started |
| 4. Observability + Security | Prometheus, Grafana, CloudTrail, Config, GuardDuty | ~$5-10/session | Not started |
| 5. Enterprise Service Mesh & Auth | Istio (mTLS), EKS Pod Identity, External Secrets Operator, AWS Cognito, OpenTelemetry | ~$1-5/session | Not started |

## Companion Application Repository
This infrastructure repository is designed to host cloud-native workloads. The primary enterprise workload running on this EKS cluster is **[aegis-core](https://github.com/BinHsu/aegis-core)**.
- **Roles & Boundaries (Zero Conflict GitOps)**:
  - **This Repo (aegis-aws-landing-zone / The Pointer)**: Pure Infrastructure as Code (Terraform), defining VPCs, EKS Clusters, DynamoDB, OIDC, and hoisting the ArgoCD Server setup. It also holds the ArgoCD `Application` CRD that simply "points" to the Aegis repository.
  - **App Repo (aegis-core / The Payload)**: A C++/Go Bazel Monorepo containing the actual ML codebase, Docker packaging (`rules_oci`), and application-level Kubernetes manifests (Deployments/Services/ConfigMaps).

*GitOps Flow*: ArgoCD in this cluster continuously monitors the `k8s/` manifests inside the Aegis repository. When application engineers push a change (e.g., increasing replica count) to the Aegis repo, ArgoCD automatically detects it and deploys the update to these EKS nodes. Because the Infra repo only defines the "Pointer" and the App repo holds the "Payload", the configurations will never conflict.


## Cost Management

- **Phase 1-2 are essentially free** (Organizations, SSO, SCPs, S3, GitHub Actions free tier)
- **Phase 3-4 cost money** — spin up only when practicing, `terraform destroy` after every session
- **Daily budget alert set at $10/day** to prevent surprise bills
- **NAT Gateway is the hidden cost killer** ($0.045/hr = $32/month if left running)

## Prerequisites

- AWS account (management account) with billing access
- GitHub account
- Terraform CLI installed locally
- AWS CLI v2 installed locally
- kubectl installed locally

## Author

Bin Hsu — Senior Software Architect, building this to prove that system design + hands-on implementation = the same person.
