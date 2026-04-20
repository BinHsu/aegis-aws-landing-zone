# -----------------------------------------------------------------------------
# Observability stack — ADR-015
# -----------------------------------------------------------------------------
# kube-prometheus-stack deployed as an ArgoCD Application. ArgoCD manages the
# Helm release lifecycle (install, upgrade, rollback); Terraform manages the
# Application CRD. This is the same pattern as the root Application in
# staging/platform/argocd.tf.
#
# The Application targets the prometheus-community Helm chart directly —
# ArgoCD supports Helm chart repos as source type. Helm values are inline
# in the Application spec, making them visible in the ArgoCD UI and
# auditable via git diff on this file.
#
# Per-cluster: each slot has its own Prometheus + Grafana. No cross-region
# federation (deferred to docs/improvements/008 if it ever becomes a
# portfolio requirement). Operator port-forwards into whichever cluster's
# Grafana they want to inspect.
#
# Access: Grafana is ClusterIP — use `kubectl port-forward` for browser
# access (same pattern as ArgoCD UI today). ALB + ACM ingress is a
# follow-up when a Route 53 domain is wired up.
#
# Chart version: pinned to a known-good release. Update via PR when
# Dependabot or manual review identifies a newer version. ArgoCD will
# not auto-upgrade — targetRevision is an exact pin.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Grafana admin password — break-glass auth only
# -----------------------------------------------------------------------------
# Regenerates on every fresh apply of the workloads layer. Intended as
# break-glass; real users should authenticate via SSO once wired up (see
# docs/improvements/009-grafana-sso-integration.md). The password lives in
# Terraform state — the state backend (S3 + KMS, shared account) is the
# trust boundary, same as every other secret this stack could conceivably
# handle short of a proper secret store.
#
# Per-cluster: each slot has its own random_password, so primary and
# slave_1 admin passwords are independent. Output by slot at the parent
# layer (grafana_admin_password_primary / grafana_admin_password_slave_1).
# -----------------------------------------------------------------------------
resource "random_password" "grafana_admin" {
  length           = 32
  special          = true
  override_special = "!@#$%^&*()-_=+" # avoid shell/URL-awkward chars for copy-paste
}

resource "kubectl_manifest" "kube_prometheus_stack" {
  provider = kubectl.this

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "kube-prometheus-stack"
      namespace = "argocd"
      finalizers = [
        "resources-finalizer.argocd.argoproj.io",
      ]
    }
    spec = {
      project = "default"

      source = {
        repoURL        = "https://prometheus-community.github.io/helm-charts"
        targetRevision = "72.6.2"
        chart          = "kube-prometheus-stack"

        helm = {
          releaseName = "kube-prometheus-stack"
          values = yamlencode({
            # -----------------------------------------------------------------
            # Prometheus
            # -----------------------------------------------------------------
            prometheus = {
              prometheusSpec = {
                retention = "24h"
                resources = {
                  requests = { cpu = "200m", memory = "512Mi" }
                  limits   = { memory = "1Gi" }
                }
                storageSpec = {
                  volumeClaimTemplate = {
                    spec = {
                      storageClassName = "gp2"
                      accessModes      = ["ReadWriteOnce"]
                      resources = {
                        requests = { storage = "20Gi" }
                      }
                    }
                  }
                }

                # -----------------------------------------------------------
                # Discovery contract — ADR-015 §Consequences (amended)
                # -----------------------------------------------------------
                # Wide-open selectors so aegis-core (and any other workload
                # team) can ship PrometheusRule / ServiceMonitor / PodMonitor
                # CRDs in any namespace and have them auto-picked-up by the
                # Operator. Without these overrides, the chart default
                # `*NilUsesHelmValues = true` makes Prometheus only select
                # resources labelled `release=<chart-release>`, which would
                # require service teams to know the platform-side chart
                # release name — brittle and leaks an internal detail.
                #
                # Documented contract: see ADR-015 §"Discovery contract"
                # and the cross-repo coordination issue on aegis-core.
                # -----------------------------------------------------------
                ruleSelector                            = {}
                ruleNamespaceSelector                   = {}
                ruleSelectorNilUsesHelmValues           = false
                serviceMonitorSelector                  = {}
                serviceMonitorNamespaceSelector         = {}
                serviceMonitorSelectorNilUsesHelmValues = false
                podMonitorSelector                      = {}
                podMonitorNamespaceSelector             = {}
                podMonitorSelectorNilUsesHelmValues     = false
              }
            }

            # -----------------------------------------------------------------
            # Grafana — lab-sized, ClusterIP access via port-forward
            # -----------------------------------------------------------------
            # adminPassword is generated by Terraform (random_password below)
            # and exposed via a `sensitive` output. It is intended as
            # break-glass access only — real users should authenticate via
            # SSO once improvements/009-grafana-sso-integration.md lands.
            # Retrieval path is documented in README.md "Grafana admin
            # password — break-glass retrieval".
            grafana = {
              resources = {
                requests = { cpu = "50m", memory = "128Mi" }
                limits   = { memory = "256Mi" }
              }
              adminPassword = random_password.grafana_admin.result
            }

            # -----------------------------------------------------------------
            # Alertmanager — disabled. No alerting targets (PagerDuty, Slack)
            # in the lab. Alert rules are still evaluated by Prometheus and
            # visible in the Prometheus UI; they just don't route anywhere.
            # -----------------------------------------------------------------
            alertmanager = {
              enabled = false
            }

            # -----------------------------------------------------------------
            # node-exporter — exclude Fargate nodes (Incident 27)
            # -----------------------------------------------------------------
            # The prometheus-node-exporter sub-chart ships a DaemonSet that
            # mounts host paths (/proc, /sys, /) to export node-level metrics.
            # Fargate nodes forbid host mounts, so DaemonSet pods scheduled
            # onto Fargate stay Pending forever. The chart default has no
            # Fargate-aware affinity — we add it here.
            #
            # Karpenter-provisioned EC2 nodes do NOT have the
            # `eks.amazonaws.com/compute-type=fargate` label, so they match
            # the NotIn clause and the DaemonSet runs normally on them.
            # -----------------------------------------------------------------
            "prometheus-node-exporter" = {
              affinity = {
                nodeAffinity = {
                  requiredDuringSchedulingIgnoredDuringExecution = {
                    nodeSelectorTerms = [{
                      matchExpressions = [{
                        key      = "eks.amazonaws.com/compute-type"
                        operator = "NotIn"
                        values   = ["fargate"]
                      }]
                    }]
                  }
                }
              }
            }

            # -----------------------------------------------------------------
            # Custom alert rules — deprecated API detection
            # -----------------------------------------------------------------
            # Per docs/principles/change-review-discipline.md §3.4, alert on
            # any non-zero value of apiserver_requested_deprecated_apis. This
            # metric is emitted by the API server when a client uses a
            # deprecated API version.
            #
            # Platform-level rule — lives with the chart per ADR-015. Service-
            # level alerts (SLO burn-rate, latency, etc.) are aegis-core's
            # responsibility and ship as separate PrometheusRule CRDs.
            # -----------------------------------------------------------------
            additionalPrometheusRulesMap = {
              deprecated-apis = {
                groups = [{
                  name = "deprecated-api-detection"
                  rules = [{
                    alert = "KubernetesDeprecatedAPIUsed"
                    expr  = "apiserver_requested_deprecated_apis > 0"
                    for   = "5m"
                    labels = {
                      severity = "warning"
                    }
                    annotations = {
                      summary     = "Deprecated Kubernetes API in use"
                      description = "The API {{ $labels.resource }}.{{ $labels.group }}/{{ $labels.version }} is deprecated. Migrate before the removal version."
                    }
                  }]
                }]
              }
            }
          })
        }
      }

      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "monitoring"
      }

      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true",
          "ServerSideApply=true",
        ]
      }
    }
  })

  depends_on = [kubernetes_namespace_v1.aegis]
}
