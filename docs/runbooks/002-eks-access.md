# Runbook 002 — EKS operator access

Scope: operational procedures for reaching the `aegis-staging` EKS cluster from the operator's laptop. Covers the authentication model, the diagnostic order for `kubectl` connectivity failures, and the per-account IAM / Access Entry wiring.

This runbook pairs with ADR-013 ("EKS Architecture" + "Design iteration"). If the design iteration section of that ADR is unfamiliar, read it first — the iteration history explains why the endpoint is currently at `0.0.0.0/0` + IAM-primary rather than the originally-planned operator-`/32` lockdown.

---

## 1. Current auth model — IAM-primary, four layers

The EKS public endpoint is open at the network layer (`public_access_cidrs = ["0.0.0.0/0"]`). **This is not the same as "unauthenticated" or "insecure".** Four auth layers gate any call to the Kubernetes API:

| # | Layer | What it enforces |
|---|---|---|
| 1 | **TLS** | API server is HTTPS-only, cluster CA is rotated by AWS. `curl http://...` is not a thing. |
| 2 | **AWS IAM (SigV4)** | Every Kubernetes API call must be signed by an AWS principal. Anonymous or expired tokens get `401 Unauthorized` before any Kubernetes RBAC is consulted. |
| 3 | **EKS Access Entries** | The signed principal must have an Access Entry in the cluster mapping it to one or more Kubernetes RBAC roles. No Access Entry = no access, regardless of IAM permissions. |
| 4 | **Kubernetes RBAC** | The mapped role must permit the specific API operation against the specific resource. `kubectl` verbs are further filtered here. |

**Attack surface is equivalent to the STS public endpoint.** Broad reachability does not translate to exploit capability without a valid credential + Access Entry + RBAC permission. Defense-in-depth at the network layer was considered but would require either self-hosted runners in the VPC (corporate Option Y in ADR-013) or whitelisting ~50 GitHub Actions published CIDRs (Option Z). For this single-operator lab, IAM-primary is the chosen model; corporate forks should adopt Option Y or Z.

**Operator session expiry is a real defense layer.** SSO sessions are capped at 8 hours. A compromised laptop loses cluster access automatically within that window.

---

## 2. Normal access — `kubectl` from the operator laptop

Prerequisites:

- An active SSO session: `aws sso login --sso-session aegis`
- The `aegis-staging-admin` profile selected: `export AWS_PROFILE=aegis-staging-admin`
- `staging/platform` Terraform has applied (cluster exists and your SSO reserved role has an Access Entry)

Fetch the kubeconfig entry (idempotent — safe to re-run):

```bash
aws eks update-kubeconfig --name aegis-staging --region eu-central-1
```

Verify cluster reachability:

```bash
kubectl get nodes            # Fargate + Karpenter-provisioned EC2
kubectl get pods -A          # baseline: CoreDNS (Fargate), Karpenter (Fargate), LB Controller + ArgoCD (EC2)
```

The `kubectl` token is derived from the SSO session and expires when the session expires. Re-running `aws sso login --sso-session aegis` refreshes it; no kubeconfig regeneration is needed.

---

## 3. Connectivity failure — diagnostic order

When `kubectl`, `aws eks describe-cluster`, or a platform-layer `terraform apply` hits an auth or connection error, follow this order. The ordering reflects the **IAM-primary** model — the network layer is last, not first.

### Step 1 — verify the SSO session is valid

```bash
aws sts get-caller-identity
```

Expected: a non-expired principal ARN pointing at `AWSReservedSSO_PlatformAdmin_*` for staging.

If this returns `ExpiredToken` or similar: `aws sso login --sso-session aegis`. SSO session expiry is the most common failure on a laptop that hasn't been touched for 8+ hours.

### Step 2 — verify kubectl is using the current session

```bash
aws eks update-kubeconfig --name aegis-staging --region eu-central-1
kubectl config current-context
```

Expected: context references `arn:aws:eks:eu-central-1:<account>:cluster/aegis-staging`.

### Step 3 — verify you authenticate as the expected principal

```bash
kubectl auth whoami
```

Expected: the SSO role ARN for `PlatformAdmin` in staging, e.g. `arn:aws:iam::251774439261:role/aws-reserved/sso.amazonaws.com/eu-central-1/AWSReservedSSO_PlatformAdmin_*`.

If the output differs: `kubectl config use-context <expected>`.

### Step 4 — verify the Access Entry + policy association exist

```bash
aws eks list-access-entries --cluster-name aegis-staging

aws eks list-associated-access-policies \
  --cluster-name aegis-staging \
  --principal-arn <your-sso-role-arn>
```

Expected: an entry for your role, associated with `arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy` at scope `cluster`.

If absent: either `staging/platform` never applied, or the `aws_eks_access_entry` / `aws_eks_access_policy_association` for your principal failed. Check Terraform state and re-apply.

### Step 5 — network layer (last)

With `public_access_cidrs = ["0.0.0.0/0"]`, the network layer is rarely the cause. But verify the endpoint resolves and accepts TLS:

```bash
ENDPOINT=$(aws eks describe-cluster --name aegis-staging \
  --query 'cluster.endpoint' --output text)
curl -sI --max-time 10 "${ENDPOINT}/healthz"
```

Expected: `HTTP/2 401` (the handler responded; no valid creds was passed). If `Connection refused`, `TLS handshake timeout`, or `Could not resolve host`, the issue is your local network, a corporate proxy, or (rarely) an EKS endpoint outage.

**If the project later narrows `public_access_cidrs` (moving to Option Y or Z in ADR-013),** this step moves higher in the diagnostic order and `curl https://checkip.amazonaws.com` becomes the quick pre-flight check again.

---

## 4. Updating `public_access_cidrs`

The CIDR list lives in `config/landing-zone.yaml` under `eks.staging.public_access_cidrs`. Editing it triggers an EKS cluster update (in-place, not a recreate) on the next `staging/platform` apply. Typical reasons to edit:

- **Corporate fork adopting Option Z** — replace `0.0.0.0/0` with the GitHub Actions published CIDRs. Recommended to maintain a small script that fetches `https://api.github.com/meta | jq '.actions'` and commits the list; the field will grow / shrink over time.
- **Corporate fork adopting Option Y** — self-hosted runners in the VPC means the cluster can be reached from inside; narrow to the operator `/32` + the runners' egress CIDR.
- **Temporary lockdown during incident response** — narrow to operator `/32` to cut off automation during investigation, then widen again once safe.

Edit sequence (PR-driven, auditable):

```bash
# 1. Edit config/landing-zone.yaml
# 2. Refresh the GitHub secret that CI reads
gh secret set LANDING_ZONE_CONFIG < config/landing-zone.yaml

# 3. PR + merge
# 4. Workload apply picks it up
gh workflow run terraform-apply-workload.yml -f env=staging
```

Emergency local apply is possible but must be followed by a PR landing the change on main immediately (per Incident 6 — never leave local-apply state un-landed).

---

## 5. Related references

- ADR-013 (`docs/decisions/013-eks-architecture.md`) — endpoint design + Design iteration section covering the 0.0.0.0/0 decision
- `CLAUDE.md` — the generic meta-rule pointing here before any `staging/platform` operation
- `terraform/environments/staging/platform/access-entries.tf` — IAM → RBAC mapping
- `docs/incidents.md` Incident 12 — the first-cold-apply discovery that the `/32` lockdown was incompatible with CI-managed Helm
- `docs/incidents.md` Incident 11 — Access Policy ARN namespace gotcha (EKS ≠ IAM)
