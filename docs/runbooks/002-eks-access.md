# Runbook 002 — EKS operator access

Scope: operational procedures for reaching the `aegis-staging` EKS cluster from the operator's laptop. Covers pre-flight checks, connectivity failure diagnosis, and the procedure for updating the allow-listed public IP when the operator's ISP reassigns it.

This runbook is the authoritative source for the operational contract behind the `eks.<env>.public_access_cidrs` field in `config/landing-zone.yaml`. See ADR-013 for the design rationale behind a public-endpoint-restricted-by-CIDR access model.

---

## 1. Pre-flight check — run this at the start of every EKS-touching session

Before the first `kubectl`, `aws eks describe-*`, or `terraform apply` against `staging/platform`, verify that the operator's current public IP still matches the allow-list in the config.

```bash
curl -s https://checkip.amazonaws.com
```

Compare the returned address with the value in `config/landing-zone.yaml` under `eks.staging.public_access_cidrs`. If they match → proceed normally. If they do not match → stop and go to section 3 before any cluster operation.

**Why this check matters.** Home ISPs (the operator is on a residential connection in Germany) reassign public IPs silently on router reboot, lease expiry, or provider-side renumbering. A mismatch does not break immediately — the allow-list is enforced by AWS on each connection, so existing kube-apiserver calls fail with a TLS handshake timeout rather than a clean 403. Diagnosing the failure downstream costs 10–20 minutes; `curl` costs 1 second. See section 4 for the `why-IP-first` diagnostic rule.

**Responsibility.** Any AI agent working on this repository MUST run the check and warn the operator if mismatched, per the rule in `CLAUDE.md`. This is not optional.

---

## 2. Normal access — `kubectl` from the operator laptop

Prerequisites:

- An active SSO session: `aws sso login --sso-session aegis`
- The `aegis-staging-admin` profile selected: `export AWS_PROFILE=aegis-staging-admin`
- The operator's public IP is in `eks.staging.public_access_cidrs` and the current `staging/platform` Terraform apply has landed.

Fetch the kubeconfig entry (idempotent — safe to re-run):

```bash
aws eks update-kubeconfig --name aegis-staging --region eu-central-1
```

Verify cluster reachability:

```bash
kubectl get nodes            # should list Karpenter-managed EC2 + Fargate
kubectl get pods -A          # baseline: CoreDNS, Karpenter controller
```

The `kubectl` token is derived from the SSO session and expires when the session expires (8 hours). Re-running `aws sso login --sso-session aegis` refreshes it; no kubeconfig re-generation is needed.

---

## 3. Connectivity failure — diagnostic order

When `kubectl`, `aws eks describe-cluster`, or a platform-layer `terraform apply` hits a network error, follow this order. The ordering is deliberate: cheapest check first, most likely cause first. Do NOT skip ahead.

### Step 1 — check your public IP

```bash
curl -s https://checkip.amazonaws.com
```

Compare with `config/landing-zone.yaml` → `eks.staging.public_access_cidrs`. If different, the IP drifted. Go to section 5 (update procedure).

**This accounts for the overwhelming majority of connectivity breakages in this project.** Only move to step 2 if the IP matches.

### Step 2 — verify the cluster endpoint resolves and is reachable at the TLS layer

```bash
ENDPOINT=$(aws eks describe-cluster --name aegis-staging \
  --query 'cluster.endpoint' --output text)
curl -sI --max-time 10 "${ENDPOINT}/healthz"
```

- `Could not resolve host` → DNS issue, likely local network misconfiguration, not the cluster.
- `TLS handshake timeout` → the CIDR allow-list is likely still rejecting you despite step 1 matching (possible IPv6 vs IPv4 split, VPN exit, corporate proxy). Try `curl -4 -s https://checkip.amazonaws.com` to confirm IPv4 egress IP.
- `HTTP/2 401` → network layer is fine, you just lack valid credentials (section 4).

### Step 3 — verify the SSO session is valid

```bash
aws sts get-caller-identity
```

If this returns a 401 / `ExpiredToken`, the SSO session has expired. Refresh:

```bash
aws sso login --sso-session aegis
```

### Step 4 — verify kubectl is using the current session

```bash
aws eks update-kubeconfig --name aegis-staging --region eu-central-1
kubectl config current-context   # should reference aegis-staging
```

### Step 5 — IAM / Access Entry diagnostics

Only reach this step after all of the above pass. A `403 forbidden from server` or `Unauthorized` response from `kubectl` at this point indicates an Access Entry or RBAC misconfiguration, not a network layer problem.

```bash
# Confirm you are authenticating as the expected principal
kubectl auth whoami

# Confirm the Access Entry exists for your SSO role
aws eks list-access-entries --cluster-name aegis-staging

# Confirm the Access Entry has cluster-admin policy attached
aws eks list-associated-access-policies \
  --cluster-name aegis-staging \
  --principal-arn <your-sso-role-arn>
```

Access Entry mismatches are rare and require Terraform changes to fix (see `terraform/environments/staging/platform/access-entries.tf`). This is deliberately the last step because it is the least likely cause and the most expensive to remediate.

---

## 4. Why IP-drift is the first suspect

The EKS public endpoint has four defensive layers: TLS, AWS IAM SigV4 auth, Kubernetes RBAC, and the CIDR allow-list. Three of those layers (TLS, IAM, RBAC) are stable — once configured, they do not change between sessions. The CIDR allow-list is the only layer whose correctness depends on a value (the operator's public IP) that drifts outside the operator's control.

Empirically: the operator's IP changes roughly every few weeks on a residential ISP. All other layers change only when this repository's Terraform changes. Therefore, on a cold-start "it doesn't work" symptom, the IP is the most likely drift site by a wide margin. Debugging IAM, kubeconfig, or RBAC first is a common time sink and explicitly discouraged — both by this runbook and by `CLAUDE.md`.

---

## 5. Update procedure when the IP has drifted

### Preferred path — PR-driven

```bash
# 1. Capture the current IP
curl -s https://checkip.amazonaws.com

# 2. Edit config/landing-zone.yaml (gitignored — local only)
#    Update eks.staging.public_access_cidrs to ["<new-ip>/32"]

# 3. Edit config/landing-zone.example.yaml too if the placeholder is stale

# 4. Commit + push + PR
git checkout -b ops/update-operator-ip
# (edit config files)
git commit -sS -m "ops: rotate operator public IP allow-list"
git push -u origin ops/update-operator-ip
gh pr create --fill

# 5. After merge — the staging/platform layer does not apply automatically
#    (it's a cost-incurring workload layer). Trigger manually:
gh workflow run terraform-apply-workload.yml -f env=staging
gh run watch   # approve in UI
```

End-to-end time: ~5 minutes (PR merge + one workload apply cycle).

### Emergency path — local apply, then land the code immediately

If the PR-driven path is blocked (CI outage, urgent need to reach the cluster):

```bash
export AWS_PROFILE=aegis-staging-admin
aws sso login --sso-session aegis

# Edit config/landing-zone.yaml locally
cd terraform/environments/staging/platform
terraform apply

# IMMEDIATELY commit the config change to main
#   — per Incident 6, code that lives only on a branch gets "corrected"
#   by the next CI apply. The local change must land on main before the
#   next baseline or workload apply.
```

Do not leave locally-applied state un-landed overnight. A merge to main between the local apply and the code landing will reconcile Terraform state against the (stale) main branch and destroy your change.

### Why there is no auto-update script (yet)

An obvious convenience would be a `scripts/update-operator-ip.sh` that reads `checkip.amazonaws.com`, rewrites the config, commits, and opens a PR. This is tracked as a future improvement. For now, the manual edit is deliberate — it forces the operator to see the new CIDR before applying it, which has prevented at least one incident of committing the wrong IP (corporate VPN exit vs. home IP) during this project's early Phase 3 work.

---

## 6. Related references

- ADR-013 (`docs/decisions/013-eks-architecture.md`) — why the endpoint is public-with-CIDR-restriction
- `CLAUDE.md` — the `before-EKS-operation` rule requiring the section 1 check
- `config/schema.json` — the schema entry that enforces the CIDR format
- `terraform/environments/staging/platform/access-entries.tf` — IAM → RBAC mapping
- Incident 6 in `docs/incidents.md` — the "local apply drift" incident that motivates the "land it on main immediately" rule in section 5
