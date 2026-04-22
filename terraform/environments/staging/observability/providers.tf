# -----------------------------------------------------------------------------
# Providers — primary-only, no slot pattern (ADR-022 §Multi-region)
# -----------------------------------------------------------------------------
# Unlike staging/platform and staging/workloads, this layer targets ONLY the
# primary cluster. grafana-operator reconciles against a single Grafana Cloud
# stack; running it in both cluster slots would make the two reconcilers race
# on identical CRDs. Data-plane scraping (Alloy) is in staging/platform and
# runs in both slots — see staging/platform/modules/eks-cluster/alloy.tf.
#
# The kubernetes/kubectl/helm providers therefore point at the primary
# cluster only. No `alias = "primary"` — there is no second alias to
# distinguish from, so the default (unaliased) provider is simpler to read
# and eliminates the `providers = {}` pass-through boilerplate used in
# slot-patterned layers.
#
# Lazy-evaluation: kubernetes/kubectl/helm provider blocks reference
# `local.clusters.primary.*` — resolved at apply time after the platform
# remote_state data source returns. At plan time on a cold apply (platform
# not yet applied), the check "platform_layer_applied" in config.tf surfaces
# a readable error; provider blocks themselves do not error at plan time
# because Terraform defers provider configuration validation until apply.
# -----------------------------------------------------------------------------

provider "aws" {
  region = local.primary_region

  default_tags {
    tags = local.tags
  }

  allowed_account_ids = [local.account_id]
}

provider "kubernetes" {
  host                   = try(local.clusters.primary.cluster_endpoint, "")
  cluster_ca_certificate = try(base64decode(local.clusters.primary.cluster_certificate_authority_data), "")

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", try(local.clusters.primary.cluster_name, ""), "--region", local.primary_eks_region.region]
  }
}

provider "kubectl" {
  host                   = try(local.clusters.primary.cluster_endpoint, "")
  cluster_ca_certificate = try(base64decode(local.clusters.primary.cluster_certificate_authority_data), "")
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", try(local.clusters.primary.cluster_name, ""), "--region", local.primary_eks_region.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = try(local.clusters.primary.cluster_endpoint, "")
    cluster_ca_certificate = try(base64decode(local.clusters.primary.cluster_certificate_authority_data), "")

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", try(local.clusters.primary.cluster_name, ""), "--region", local.primary_eks_region.region]
    }
  }
}

# -----------------------------------------------------------------------------
# grafana/grafana — cloud-level only (ADR-022 §Auth and secret chain)
# -----------------------------------------------------------------------------
# Single `cloud` provider instance. Authenticates with the one-time human-
# provisioned bootstrap token from SSM PS; scope-limited to managing Cloud
# Access Policies and stack service accounts. Used to provision the Alloy
# access policy+token and the grafana-operator stack service account+token.
#
# A stack-level provider is NOT declared here because grafana-operator
# (running inside the cluster) is what talks to the stack API day-to-day.
# If a future use-case needs Terraform-side stack-level provisioning (e.g.
# pre-creating a Grafana folder structure), declare a `stack` alias then.
# Declaring it unused today would trigger a validation warning and pin a
# token reference that may not exist on a fresh apply.
#
# Dummy credentials when observability_enabled=false: Terraform evaluates
# provider config at init. The bootstrap_token data source is count-gated
# so on a disabled layer Terraform never dereferences the SSM PS value,
# but the provider block itself must evaluate to something.
# -----------------------------------------------------------------------------

provider "grafana" {
  alias = "cloud"

  cloud_access_policy_token = try(data.aws_ssm_parameter.bootstrap_token[0].value, "unset")
}
