# staging/observability

Peer Terraservice layer for Grafana Cloud downstream identities + the primary-only grafana-operator install. Implements the control-plane half of the observability stack described in [ADR-022](../../../../docs/decisions/022-observability-backend-grafana-cloud.md) and [ADR-023](../../../../docs/decisions/023-observability-responsibility-model.md).

## What this layer owns

- **Downstream Grafana Cloud identities** — Cloud Access Policy (Alloy, metrics:write + logs:write) and stack Service Account (grafana-operator, stack Admin). Both are provisioned from the one-time bootstrap token in SSM PS via the `grafana/grafana` Terraform provider.
- **SSM PS SecureString writeback** — Alloy token, grafana-operator token, and the `team-webhooks-slack-aegis` placeholder (ldz #126 Coordination Point 1 for aegis-core).
- **ExternalSecret CRDs** — three resources that sync the SSM PS values into Kubernetes Secrets via the `aegis-ssm` ClusterSecretStore installed in staging/platform.
- **grafana-operator Helm release** — primary cluster only, per ADR-022 §Multi-region. The slave cluster is data-plane-only; running grafana-operator there would race on Grafana Cloud control-plane state.
- **Platform Grafana CRDs** — `Grafana` (target stack), root `GrafanaNotificationPolicy`, three `GrafanaDashboard` CRDs (Kubernetes overview, Karpenter, grafana-operator meta), and four `PrometheusRule` CRDs (NodeNotReady, DeprecatedAPIUsed, GrafanaOperatorReconcileFailed, GrafanaCloudCardinalityApproaching8k).

## What this layer does NOT own

- **Alloy, prometheus-operator-crds, External Secrets Operator, kube-state-metrics** — installed by staging/platform (PR-1).
- **The primary-region secrets CMK (`alias/aegis-staging-secrets`)** — created by staging/bootstrap.
- **Service-team dashboards, contact points, notification-policy leaves** — aegis-core repo per ADR-023 §Domain split.
- **Slave-cluster control plane** — by design there is no slave observability control plane; Alloy in staging/platform handles slave data-plane.

## Apply order

```
network → platform → workloads → observability
```

Observability depends on workloads because the `team-webhooks` ExternalSecret targets the `aegis` namespace owned by workloads. CI enforces the order in `.github/workflows/terraform-apply-workload.yml`.

## First-time operator steps

See [docs/runbooks/006-grafana-cloud-onboarding.md](../../../../docs/runbooks/006-grafana-cloud-onboarding.md) Part 4 for the one-time Grafana Cloud signup + bootstrap token flow. Until the bootstrap token is put in SSM PS, `terraform apply` on this layer exits with `NoSuchKey` on the bootstrap-token data source — that's the intended operator-facing failure mode.

## Slack webhook placeholder

`tokens.tf` creates `/aegis/staging/grafana-cloud/team-webhooks-slack-aegis` with a placeholder value and `lifecycle.ignore_changes = [value]`. Operator overwrites out-of-band:

```bash
AWS_PROFILE=aegis-staging-admin aws ssm put-parameter \
  --region eu-central-1 \
  --name /aegis/staging/grafana-cloud/team-webhooks-slack-aegis \
  --type SecureString --key-id alias/aegis-staging-secrets \
  --value 'https://hooks.slack.com/services/T.../B.../...' \
  --overwrite
```

External Secrets picks up the real value within its refresh interval (1h default) and populates the `team-webhooks` K8s Secret key `slack-aegis` in the `aegis` namespace, fulfilling the aegis-core GrafanaContactPoint contract (ADR-023 §Secret plumbing model).

## Teardown

**Pre-teardown step** per ADR-022 §Teardown: delete Grafana CRDs before destroying this layer, or Grafana Cloud will carry orphan dashboards and routing. PR-4 wires this into `terraform-teardown-workload.yml` as the first stage. Manual form:

```bash
kubectl delete grafanadashboards,grafanacontactpoints,grafananotificationpolicies,grafananotificationpolicyroutes --all -A
# wait ~2 minutes for finalizers
terraform destroy
```
