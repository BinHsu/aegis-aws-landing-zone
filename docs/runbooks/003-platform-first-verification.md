# Runbook 003 — Platform first-time verification

Scope: post-apply verification of the `staging/platform` layer. Runs end-to-end after `terraform-apply-workload.yml` reports success, confirming every installed component is healthy before declaring the session "cluster is up".

This runbook is the authoritative "what all green looks like" checklist. If a step fails, jump to the specified diagnostic: most failures in this layer trace back to one of Incidents 10–17 in [`docs/incidents.md`](../incidents.md) with a direct fix pointer.

**Time budget**: ~5 minutes when everything is healthy. Up to 30 minutes if you hit one of the documented incidents.

---

## 1. Pre-flight

Before running any of the steps below:

```bash
# Operator IP sanity — see runbook 002 section 1 for the details of why
curl -s https://checkip.amazonaws.com
# Compare against config/landing-zone.yaml → eks.staging.public_access_cidrs.
# With the default 0.0.0.0/0, this is a courtesy check rather than a gate.

# Fresh SSO session
export AWS_PROFILE=aegis-staging-admin
aws sso login --sso-session aegis

# Local kubectl / helm installed
which kubectl helm || brew install kubectl helm
```

---

## 2. Cluster API access

```bash
aws eks update-kubeconfig --name aegis-staging --region eu-central-1
kubectl config current-context
# Expected: arn:aws:eks:eu-central-1:<account>:cluster/aegis-staging

kubectl auth whoami
# Expected: arn:aws:iam::<account>:role/aws-reserved/sso.amazonaws.com/eu-central-1/AWSReservedSSO_PlatformAdmin_*

kubectl get ns
# Expected namespaces: argocd, default, karpenter, kube-node-lease, kube-public, kube-system
```

If any step fails, see [Runbook 002 §3](002-eks-access.md) diagnostic order.

---

## 3. System pods healthy

```bash
kubectl get pods -A
```

Expected output (names will have random suffixes):

| Namespace | Pod | Status | Where |
|---|---|---|---|
| `karpenter` | `karpenter-*` | Running | Fargate |
| `kube-system` | `coredns-*` × 2 | Running | Fargate |
| `kube-system` | `aws-load-balancer-controller-*` | Running | EC2 (Karpenter-provisioned) |
| `kube-system` | `aws-node-*` | Running | EC2 (DaemonSet) |
| `kube-system` | `kube-proxy-*` | Running | EC2 (DaemonSet) |
| `argocd` | `argocd-application-controller-0` | Running | EC2 |
| `argocd` | `argocd-applicationset-controller-*` | Running | EC2 |
| `argocd` | `argocd-notifications-controller-*` | Running | EC2 |
| `argocd` | `argocd-redis-*` | Running | EC2 |
| `argocd` | `argocd-repo-server-*` | Running | EC2 |
| `argocd` | `argocd-server-*` | Running | EC2 |

Node distribution check:

```bash
kubectl get nodes
```

Expected: 3× Fargate nodes (CoreDNS × 2 + Karpenter controller) + at least 1× EC2 node provisioned by Karpenter.

**If CoreDNS pods are Pending forever**: you hit [Incident 16 (CoreDNS/Fargate race)](../incidents.md). Immediate fix: `kubectl -n kube-system rollout restart deployment coredns`. Long-term fix: see the codified `null_resource` in `terraform/environments/staging/platform/` (or the `aws_eks_addon` with `configurationValues` pattern).

**If Karpenter controller is in CrashLoopBackOff**: check logs with `kubectl -n karpenter logs -l app.kubernetes.io/name=karpenter --tail=50`. If the error mentions `sts.eu-central-1.amazonaws.com: i/o timeout`, this is the DNS cascade from Incident 16 — CoreDNS needs to come up first.

---

## 4. Helm releases

```bash
helm list -A
```

Expected: three `deployed` releases.

```
NAME                          NAMESPACE    STATUS
karpenter                     karpenter    deployed
aws-load-balancer-controller  kube-system  deployed
argocd                        argocd       deployed
```

**If any is `failed`**: `helm uninstall <name> -n <ns>` first, then re-run `terraform apply` (or dispatch the workload workflow). The `helm_release` resource will install fresh. See [Incident 13](../incidents.md) for the namespace-creation variant and [Incident 17](../incidents.md) for the webhook-race variant.

---

## 5. Karpenter is alive + ready to provision

```bash
kubectl get nodepool,ec2nodeclass
```

Expected:

```
NAME                            NODECLASS   NODES   READY   AGE
nodepool.karpenter.sh/default   default     1       True    ...

NAME                                     READY   AGE
ec2nodeclass.karpenter.k8s.aws/default   True    ...
```

**Both must show `READY: True`**. If they show `False` or blank:

- Check the Karpenter controller logs: `kubectl -n karpenter logs -l app.kubernetes.io/name=karpenter --tail=30`
- Look for `"karpenter version is not compatible with K8s version X"` warnings — these are usually informational; Karpenter proceeds anyway
- Look for `"no subnets found"` — subnet discovery tag mismatch. Verify `terraform/environments/staging/network/main.tf` has `kubernetes.io/role/internal-elb = "1"` on private subnets.

Check if Karpenter has already provisioned EC2:

```bash
kubectl get nodeclaim
```

Expected: at least one `NodeClaim` with `READY: True` and a `NODE` filled in (e.g., `ip-10-0-9-206.eu-central-1.compute.internal`). This is the EC2 that LB Controller + ArgoCD are running on.

**If NodeClaim is stuck in `Unknown` status**: likely [Incident 15 (Spot SLR missing)](../incidents.md). Check Karpenter logs for `AuthFailure.ServiceLinkedRoleCreationNotPermitted`. Fix:

```bash
aws iam create-service-linked-role --aws-service-name spot.amazonaws.com
# Then force Karpenter to retry:
kubectl delete nodeclaim <stuck-name>
# Karpenter will create a new NodeClaim on the next reconcile.
```

Long-term fix: the codified `aws_iam_service_linked_role` in `terraform/environments/staging/bootstrap/` ensures the SLR exists before any Karpenter apply.

---

## 6. IRSA is wired correctly

Random but thorough check: pods with IRSA-bound ServiceAccounts should actually be able to call AWS APIs.

```bash
# LB Controller should be able to describe VPC resources
kubectl -n kube-system logs -l app.kubernetes.io/name=aws-load-balancer-controller --tail=20 | grep -i "error\|fail" | head -5
# Expect nothing. If you see "NoCredentialProviders" or "AccessDenied", the
# IRSA role ARN annotation on the ServiceAccount is wrong, or the IAM
# policy is missing an action. Check:
#   kubectl -n kube-system get sa aws-load-balancer-controller -o jsonpath='{.metadata.annotations}'
```

Karpenter should be able to describe EC2 instance types (check the earlier "found provisionable pod(s)" log line on Karpenter controller — if present, IRSA worked; if instead you see STS errors, IRSA is broken).

---

## 7. ArgoCD UI access — initial admin login

ArgoCD's server Service is `ClusterIP` (not publicly exposed). Access via `kubectl port-forward`:

```bash
# Retrieve the initial admin password (stored by ArgoCD in a K8s Secret)
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
# Prints the password to stdout; copy it.

# Port-forward ArgoCD UI to localhost:8080
kubectl -n argocd port-forward svc/argocd-server 8080:80
# Leave this running in one terminal. In a browser, visit http://localhost:8080
#   - Accept the self-signed certificate warning (ArgoCD serves its own TLS)
#   - Username: admin
#   - Password: (the one from the previous command)
```

Once logged in:

- **Applications tab** — should list the `root` Application (the app-of-apps root pointed at `aegis-core/apps/staging`)
- **Root Application status** — `Health: Healthy`, `Sync: Unknown` is expected if `aegis-core/apps/staging/` does not yet exist. Sync transitions to `Synced` once aegis-core has content there.

### ArgoCD password hygiene

The `argocd-initial-admin-secret` is a K8s Secret (base64-encoded, not encrypted at rest beyond EKS default encryption). For this lab it's fine — teardown destroys the cluster and the password with it. Production hardening:

1. Log in once, navigate to `User Info` → change admin password
2. `kubectl -n argocd delete secret argocd-initial-admin-secret` (only valid until first password change)
3. Consider wiring external SSO (Dex) if more than one operator needs UI access — out of scope for this phase.

---

## 8. End-to-end smoke test (optional)

If you want to verify Karpenter actually provisions on demand under load, not just at bootstrap:

```bash
# Create a test Deployment that requests more CPU than current nodes can fit
kubectl create deployment nginx-test --image=nginx --replicas=10
kubectl set resources deployment nginx-test --requests=cpu=500m
# Watch Karpenter launch new EC2 instances
kubectl get nodes -w
# After a few minutes you should see new ip-* nodes appearing.

# Scale down to trigger consolidation
kubectl scale deployment nginx-test --replicas=0
# Within ~30 seconds (the consolidateAfter value), idle nodes drain.
kubectl delete deployment nginx-test
```

This exercises the full Karpenter lifecycle: provision on schedule pressure, deprovision on consolidation.

---

## 9. What "fully green" looks like

All nine items below must hold simultaneously. If any one fails, do not declare the platform up — the cluster is in a brittle state that will cascade-fail under load.

- [ ] `kubectl auth whoami` returns the expected SSO role ARN
- [ ] `kubectl get ns` shows argocd, karpenter, kube-system, etc.
- [ ] `helm list -A` shows 3 releases all `deployed`, zero `failed`
- [ ] CoreDNS × 2 Running on Fargate
- [ ] Karpenter controller Running (not CrashLoopBackOff)
- [ ] LB Controller Running on EC2
- [ ] ArgoCD 6/6 pods Running on EC2
- [ ] `NodePool` and `EC2NodeClass` both `READY: True`
- [ ] Can login to ArgoCD UI via port-forward with initial admin password

---

## 10. Related references

- [Runbook 001](001-bootstrap-aws-account.md) — AWS account + Control Tower bootstrap (run once per AWS organization, before any platform apply)
- [Runbook 002](002-eks-access.md) — operator access model (the four auth layers)
- [ADR-013](../decisions/013-eks-architecture.md) — platform design + Design iteration section
- [`docs/incidents.md`](../incidents.md) — Incidents 10–17 cover cold-apply gotchas referenced in the diagnostic sections above
- [`terraform/environments/staging/platform/README.md`](../../terraform/environments/staging/platform/README.md) — per-file breakdown of the platform layer
