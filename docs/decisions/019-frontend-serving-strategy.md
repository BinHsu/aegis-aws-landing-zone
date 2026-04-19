# 019. Frontend serving strategy — S3 + CloudFront

## Status
Accepted

## Context

aegis-core's Phase 4a-5 ships a static SPA bundle (React + Vite, output at `frontend_web/dist/`). It is not a server — it is HTML / JS / CSS / fonts that need to be served from somewhere. The question is where.

Three candidates, each with a different split of responsibility between ldz (platform) and aegis-core (workload):

| Option | aegis-core side | ldz side | Cost (persistent) |
|---|---|---|---|
| A. Bundle into gateway image | Add a static-file handler to the Go gateway | Nothing extra — gateway Deployment already serves | $0 |
| B. Separate frontend container (nginx/caddy) | New OCI image baked with the SPA + nginx | New Deployment + Service + Ingress routing | ALB overhead |
| C. S3 + CloudFront | CI step syncs `dist/` to S3, invalidates CDN | S3 bucket + CloudFront + ACM + Route53 + OIDC role | ~$0.50/month |

Context from the cross-repo thread (ldz #90 → aegis-core #91):

- aegis-core is deployed on EKS via ArgoCD; backend (gateway + engine) needs a load balancer ALB for WebSocket + gRPC. That ALB is required regardless.
- `binhsu.org` is the lab's domain (on Cloudflare DNS). A subdomain delegation to Route53 is acceptable for the `staging.` namespace (runbook 004 covers it).
- The lab is EU-operator + EU-user; CloudFront's PriceClass_100 (North America + Europe edges) is sufficient.
- Portfolio angle matters — this repo is public and is meant to demonstrate senior-level infrastructure choices.

## Decision

**Option C — S3 + CloudFront, with OAC (Origin Access Control), split subdomains.**

Implementation lives in `terraform/environments/staging/edge/` as a dedicated Terraservice. Key shape:

- **S3 bucket** (`aegis-staging-frontend-<account-id>`): OAC-locked, public access fully blocked, SSE-S3 encryption, versioning enabled with 30-day non-current-version expiration.
- **CloudFront distribution**: PriceClass_100, default root object `/index.html`, SPA 404/403 rewrite to `/index.html` with status 200, `redirect-to-https`, Managed-CachingOptimized cache policy, IPv6 enabled.
- **ACM certificate** in `us-east-1` (CloudFront service constraint), DNS-validated via Route53 in the primary region. Single SAN = `aegis-app.staging.binhsu.org` today; adds `aegis-app.prod.binhsu.org` when prod cut lands.
- **Route53 hosted zone** for `staging.binhsu.org` (subdomain-delegated from Cloudflare-hosted `binhsu.org`), with A + AAAA alias records for `aegis-app.staging.binhsu.org` → CloudFront.
- **OIDC role** `github-actions-aegis-core-frontend` — assumed by aegis-core's `release-staging-frontend.yml` workflow. Trust scope: `sub = repo:BinHsu/aegis-core:ref:refs/heads/main` + `job_workflow_ref` pinned to that specific workflow file path + ref. Inline policy: `s3:PutObject`, `s3:DeleteObject`, `s3:ListBucket` on the frontend bucket + `cloudfront:CreateInvalidation` on the specific distribution.
- **S3 bucket policy** — two statements: `AllowCloudFrontRead` (scoped to this specific distribution ARN via OAC) and `DenyPutExceptFromOIDCRole` (mirrors the ECR #83/#89 pattern — a dev running `aws s3 sync` from their laptop gets AccessDenied).

### Domain naming

- `aegis-app.staging.binhsu.org` → frontend (CloudFront)
- `aegis-api.staging.binhsu.org` → gateway (ALB, Phase 4c, provisioned when workloads layer migrates)

Hyphenated project-prefix form, **not** `app.staging.binhsu.org`:

- `binhsu.org` is a personal umbrella domain; generic `app.` could collide with future non-aegis projects
- Matches the `aegis-<env>-<purpose>` pattern already used in AWS account names (`aegis-staging`, `aegis-management`) and S3 bucket names (`aegis-staging-frontend-...`)
- `aegis-app` / `aegis-api` is clearer-at-a-glance than `aegisapp` / `aegisapi` (run-together form)

### Why split subdomains (not path-based routing at the CDN)

CloudFront can front both the frontend S3 and the backend ALB via origin groups + path-pattern behaviors. We rejected this because:

- **WebSocket path (`/ws/*`)** for the gateway is session-affinity-sensitive (ADR-014). Routing through CloudFront would add a non-transparent hop; CloudFront's WebSocket semantics are not as battle-tested as ALB's.
- **gRPC over HTTP/2** for the gateway's public gRPC-Web surface — CloudFront does support HTTP/2 but has a 30-second per-request timeout ceiling that WebSocket-like long-lived streams can violate. ALB has configurable idle timeout up to 4000 seconds.
- Path-pattern behaviors require one distribution to straddle two very different workloads (static assets + live bidirectional traffic). The abstraction cost isn't worth avoiding two subdomains.
- Split subdomains mean CORS is explicit in both directions (`aegis-app` → `aegis-api` is cross-origin; the gateway's `AEGIS_ALLOWED_ORIGINS` env permits exactly the frontend hostname). Explicit is maintainable.

### Why OAC, not legacy OAI

CloudFront has two mechanisms for restricting S3 origin access:

- **OAI (Origin Access Identity)** — legacy, uses a signed-URL-like scheme, doesn't support KMS-encrypted buckets, AWS has declared it as "still available" but pushes new installations to OAC
- **OAC (Origin Access Control)** — current, uses SigV4, supports everything OAI does plus KMS-encrypted S3, is the recommended choice for new distributions as of 2022+

We picked OAC despite using SSE-S3 (not SSE-KMS) because: zero downside today, and if we ever upgrade to SSE-KMS (e.g., compliance requirement), we don't have to re-architect.

### Why PriceClass_100

CloudFront pricing has three tiers:
- **PriceClass_All** — global edge coverage, highest request fees
- **PriceClass_200** — North America + Europe + Asia (excludes South America, South Africa, Middle East)
- **PriceClass_100** — North America + Europe only

At lab scale, request volume is noise-level. The operator is EU-based (Germany). Users for demo purposes are likely EU/NA. PriceClass_100 is the cheapest tier that covers the demo scenario. Can be bumped without re-architecture if traffic patterns demand it.

## Alternatives Considered

### A. Bundle frontend into gateway image

Rejected. Gateway is a Go HTTP/gRPC server, not a static file server. Serving 1MB of JS from the Go pod would:

- Force every frontend change to rebuild + repush the gateway image (tightly coupled deploy cadence)
- Waste gateway CPU serving static content (Karpenter scales gateway by request-rate; static requests inflate the metric without actually needing backend resources)
- Miss out on edge caching (every user fetch hits origin EU, not their nearest POP)
- Make TLS termination entangled (gateway's ALB already has ACM, but if we later add a WAF at CloudFront for the static side, we'd be doubling up the TLS story)

Cheapest to implement, lowest operational maturity. Rejected on portfolio grounds alone (a platform engineer shouldn't serve JS from Go).

### B. Separate frontend container (nginx / caddy)

Rejected. All of the operational cost of a second Deployment (K8s manifests, resource requests/limits, Pod autoscaling, health checks, log pipeline) for zero of CloudFront's edge-cache benefit. In-cluster static serving is the worst of both worlds.

Only makes sense in environments where CloudFront is unavailable (e.g., private on-prem deploys) — not relevant here.

### C.1 CloudFront + S3 with path-based routing to ALB

Considered briefly. Reasons to reject covered above under "Why split subdomains".

### D. Cloudflare Pages / Workers

Cloudflare already hosts the root domain DNS. Cloudflare Pages would serve the SPA with comparable edge caching at comparable cost. Rejected because:

- The aegis-core CI needs to push to the asset store. Cloudflare Pages' Git integration wants its own repo connection; we'd be adding a second CI credential surface (Cloudflare API token alongside the GitHub OIDC → AWS pattern).
- Portfolio angle: the rest of the infrastructure is AWS-native. Adding a Cloudflare Pages layer would be inconsistent without a reason the demo needs.
- Harder to audit: CloudFront invalidations + access logs ship to CloudWatch Logs / S3; Cloudflare Pages has its own observability surface.

Cloudflare stays as the registrar-level DNS for `binhsu.org` apex; all compute lives on AWS.

### E. Terraform the Cloudflare side (full move to Route53 + ACM)

Considered. Rejected because:

- The runbook 004 subdomain-delegation pattern keeps the rest of the domain (`binhsu.org`, `www.binhsu.org`, any future non-aegis service) on Cloudflare where the operator already manages it.
- Moving the apex would require updating registrar NS records (one-time manual step), plus re-creating any existing Cloudflare-managed records in Route53 (email auth TXT records, any unrelated subdomains).
- Subdomain delegation is the lower-blast-radius choice — if we ever want to move the apex, we still can, without it being the first step.

## Consequences

### Easier

- Frontend deploys are a CI-owned `aws s3 sync` + `aws cloudfront create-invalidation`. Takes ~30 seconds; no cluster involvement.
- Edge cache hits mean typical user latency is < 100ms globally even though origin is eu-central-1.
- The aegis-core side owns what to deploy; ldz owns where it goes. Clean split, per ADR-007.
- Changes to aegis-core don't trigger re-applies of K8s cluster resources. Frontend-only change ships without touching Karpenter / ArgoCD / any workload pod.
- The ALB stays scoped to backend APIs (WebSocket + gRPC). Clean responsibilities.

### Harder

- One more Terraservice to maintain (`staging/edge/`). Cold-apply takes ~5 minutes (CloudFront distribution provisioning is slow).
- Cross-region provider alias for ACM (`aws.cloudfront_cert` pointing at us-east-1). One extra provider block per edge Terraservice.
- DNS delegation is a one-time manual step on the parent DNS provider (Cloudflare) — documented in runbook 004. Not hard but not pure-Terraform.
- Prod environment will need its own edge Terraservice (or this one parameterized by env) when ldz #79 Q1 lands. Additional cert SAN + ACM propagation delay.

### Cross-repo impact

aegis-core owns:

- `.github/workflows/release-staging-frontend.yml` — OIDC role assumption, s3 sync, CloudFront invalidation
- `frontend_web/dist/` Vite build output
- Gateway CORS allowlist (`AEGIS_ALLOWED_ORIGINS` env var permits `https://aegis-app.staging.binhsu.org`)
- No container image for the frontend (intentional — Option A was rejected)

ldz owns:

- Everything in `terraform/environments/staging/edge/`
- The three values aegis-core consumes as GitHub Actions secrets / env hardcodes: bucket name, distribution ID, OIDC role ARN (posted on issue #91)

Coordination: if aegis-core renames `release-staging-frontend.yml`, the `job_workflow_ref` trust condition on the OIDC role needs an ldz-side edit (a one-line PR). Flagged as a cross-repo coupling point.

### Cost

At lab scale:

| Item | Monthly (persistent) |
|---|---|
| S3 storage (2 GB ceiling, versioned) | < $0.05 |
| CloudFront requests (PriceClass_100, ~10K/month demo) | ~$0.15 |
| CloudFront data transfer (1 GB/month demo) | ~$0.08 |
| Route53 hosted zone (1) | $0.50 |
| ACM certificate | $0 |
| IAM role | $0 |
| **Total** | **~$0.80** |

Negligible. If the demo goes viral or we cut a prod, traffic is the variable — but even 10× growth keeps this below $10/month.

### Reversibility

Fully reversible. `terraform destroy` on `staging/edge/` removes:

- CloudFront distribution (~15 min AWS-side deletion)
- ACM certificate (immediate; validation records + cert together)
- S3 bucket (must be empty; apply `force_destroy = true` at destroy time if it has objects)
- Route53 zone (removes the 4 NS records at Cloudflare become pointing at a non-existent zone — operator cleans those manually per runbook 004 rollback)
- IAM role + policy

Recovery path if bucket gets nuked by accident: state versioning keeps the previous S3 assets for 30 days; the last successful aegis-core deploy is also recoverable by re-running the workflow.

### Portfolio implication

1. **Edge-first static serving** is the cloud-native canonical pattern for SPAs; demonstrates the engineer can build production-grade delivery, not just compute.
2. **OAC + deny-by-default bucket policy** is the current best-practice S3 + CloudFront lockdown; demonstrates defense-in-depth thinking.
3. **Subdomain delegation** (keep parent domain on existing provider, Terraform the subdomain only) is lower-blast-radius than "move everything" — demonstrates pragmatic migration posture.
4. **`job_workflow_ref` OIDC condition** pinning the CI workflow file path is one layer tighter than `sub`-only; demonstrates GitHub-OIDC threat-model familiarity beyond the 80%-common trust policy shape.
5. **Split subdomains over path-based CDN routing** is the right-for-the-job choice when backend traffic is WebSocket-heavy; demonstrates understanding of CDN limits vs ALB semantics, not just "use CloudFront because it's there".

## Compliance / residency

- S3 bucket lives in `eu-central-1` (EU operator + EU user demo).
- CloudFront is a global service but honors data-at-rest for the S3 origin.
- ACM cert lives in `us-east-1` (CloudFront constraint, unavoidable).
- The frontend contains no PII or session data — it's public HTML/JS. Compliance surface is minimal.

## References

- Cross-repo coordination: [ldz #91](https://github.com/BinHsu/aegis-aws-landing-zone/issues/91), [ldz #90](https://github.com/BinHsu/aegis-aws-landing-zone/issues/90)
- ADR-014 (ALB session affinity) — why WebSocket path stays on ALB, not CDN
- ADR-018 §3 amended — role-based provider aliases (this Terraservice uses the `cloudfront_cert` alias for the us-east-1 ACM provider)
- Runbook 004 — DNS delegation Cloudflare → Route53
- ECR defense-in-depth pattern (PRs #86 / #89) — the S3 DenyPut bucket policy follows the same shape
