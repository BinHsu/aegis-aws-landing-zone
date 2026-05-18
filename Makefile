# =============================================================================
# Makefile — local orchestrator for the AWS landing zone
# =============================================================================
# CI (.github/workflows/) is the canonical apply path. This Makefile is the
# local override / cold-apply path — it runs the same per-region loop the
# workflows do (ADR-032 external orchestration).
#
# Quick start:
#   make dev-setup        # install the pinned toolchain into ./bin
#   make help             # list targets
#   make regions          # show the active region list for ENV
#
# Variables:
#   ENV=staging           # target environment (staging | prod)
#   AUTO_APPROVE=          # set to "-auto-approve" to skip apply/destroy prompts
# =============================================================================

ENV          ?= staging
AUTO_APPROVE ?=
CONFIG       := config/landing-zone.yaml
TF_DIR       := terraform/environments
BIN          := $(CURDIR)/bin
WORKLOAD_LAYERS := network platform workloads

# Pinned tools (./bin) take precedence over anything on the host.
export PATH := $(BIN):$(PATH)

# --- values derived from config/landing-zone.yaml ----------------------------
# All three are empty if the config is missing — targets that need them guard
# with _check-config.
ACTIVE_REGIONS := $(shell python3 -c "import yaml;c=yaml.safe_load(open('$(CONFIG)'));print(' '.join(r['region'] for r in c.get('eks',{}).get('$(ENV)',{}).get('regions',[])))" 2>/dev/null)
PRIMARY_REGION := $(shell python3 -c "import yaml;c=yaml.safe_load(open('$(CONFIG)'));print(next(r['name'] for r in c['regions'] if r['role']=='primary'))" 2>/dev/null)
TFSTATE_BUCKET := $(shell python3 -c "import yaml;c=yaml.safe_load(open('$(CONFIG)'));print(c['organization']['name']+'-terraform-state-'+str(c['accounts']['shared']['id']))" 2>/dev/null)

.DEFAULT_GOAL := help
.PHONY: help dev-setup fmt validate config-check regions \
        workload-plan workload-apply workload-destroy \
        observability-apply cold-apply teardown _check-config _cost-warning

help: ## Show this help
	@echo "Landing zone — local orchestrator (ENV=$(ENV))"
	@echo
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Active regions for ENV=$(ENV): $(ACTIVE_REGIONS)"

# --- setup / quality ---------------------------------------------------------

dev-setup: ## Install the pinned toolchain (tflint, gitleaks, kubeconform, jq) into ./bin
	./scripts/install-tools.sh

fmt: ## terraform fmt across the whole tree
	terraform fmt -recursive terraform/

config-check: _check-config ## Validate config/landing-zone.yaml + sync backend.tf files
	python3 scripts/validate-config.py
	./scripts/configure-backends.sh

regions: _check-config ## Print the active region list for ENV
	@echo "ENV=$(ENV)  primary=$(PRIMARY_REGION)  bucket=$(TFSTATE_BUCKET)"
	@echo "regions: $(ACTIVE_REGIONS)"

# --- workload layers (per region, ADR-032) -----------------------------------
# network -> platform -> workloads, looped over every region in
# eks.$(ENV).regions[]. State keys are region-scoped; backend.tf is partial.

workload-plan: _check-config ## Plan network/platform/workloads for every region
	@for region in $(ACTIVE_REGIONS); do \
	  for layer in $(WORKLOAD_LAYERS); do \
	    echo ">>> plan $(ENV)/$$layer @ $$region"; \
	    terraform -chdir=$(TF_DIR)/$(ENV)/$$layer init -reconfigure -input=false \
	      -backend-config="bucket=$(TFSTATE_BUCKET)" \
	      -backend-config="key=$(ENV)/$$region/$$layer/terraform.tfstate" \
	      -backend-config="region=$(PRIMARY_REGION)" || exit 1; \
	    TF_VAR_region=$$region terraform -chdir=$(TF_DIR)/$(ENV)/$$layer plan -input=false || exit 1; \
	  done; \
	done

workload-apply: _check-config _cost-warning ## Apply network/platform/workloads for every region
	@for region in $(ACTIVE_REGIONS); do \
	  for layer in $(WORKLOAD_LAYERS); do \
	    echo ">>> apply $(ENV)/$$layer @ $$region"; \
	    terraform -chdir=$(TF_DIR)/$(ENV)/$$layer init -reconfigure -input=false \
	      -backend-config="bucket=$(TFSTATE_BUCKET)" \
	      -backend-config="key=$(ENV)/$$region/$$layer/terraform.tfstate" \
	      -backend-config="region=$(PRIMARY_REGION)" || exit 1; \
	    TF_VAR_region=$$region terraform -chdir=$(TF_DIR)/$(ENV)/$$layer apply -input=false $(AUTO_APPROVE) || exit 1; \
	  done; \
	done

workload-destroy: _check-config ## Destroy workloads/platform/network for every region (reverse order)
	@for region in $(ACTIVE_REGIONS); do \
	  for layer in workloads platform network; do \
	    echo ">>> destroy $(ENV)/$$layer @ $$region"; \
	    terraform -chdir=$(TF_DIR)/$(ENV)/$$layer init -reconfigure -input=false \
	      -backend-config="bucket=$(TFSTATE_BUCKET)" \
	      -backend-config="key=$(ENV)/$$region/$$layer/terraform.tfstate" \
	      -backend-config="region=$(PRIMARY_REGION)" || exit 1; \
	    TF_VAR_region=$$region terraform -chdir=$(TF_DIR)/$(ENV)/$$layer destroy -input=false $(AUTO_APPROVE) || exit 1; \
	  done; \
	done

observability-apply: _check-config ## Apply the primary-only observability layer (single state)
	terraform -chdir=$(TF_DIR)/$(ENV)/observability init -input=false
	terraform -chdir=$(TF_DIR)/$(ENV)/observability apply -input=false $(AUTO_APPROVE)

cold-apply: workload-apply observability-apply ## Full cold apply — every region, then observability
	@echo "Cold apply complete. Verify per docs/runbooks/003-platform-first-verification.md."
	@echo "REMINDER: run 'make teardown' at session end — workload layers bill while idle."

teardown: _check-config ## Tear down observability then all workload layers (cost-safe session close)
	terraform -chdir=$(TF_DIR)/$(ENV)/observability init -input=false
	terraform -chdir=$(TF_DIR)/$(ENV)/observability destroy -input=false $(AUTO_APPROVE)
	$(MAKE) workload-destroy ENV=$(ENV) AUTO_APPROVE=$(AUTO_APPROVE)

# --- guards ------------------------------------------------------------------

_check-config:
	@test -f $(CONFIG) || { \
	  echo "ERROR: $(CONFIG) not found. Copy config/landing-zone.example.yaml and fill it in."; exit 1; }
	@test -n "$(ACTIVE_REGIONS)" || { \
	  echo "ERROR: no eks.$(ENV).regions[] in $(CONFIG) — nothing to orchestrate."; exit 1; }

_cost-warning:
	@echo "============================================================"
	@echo " COST WARNING — workload-apply creates billable resources:"
	@echo "   EKS control plane ~\$$73/mo/cluster, NAT Gateway ~\$$32/mo,"
	@echo "   ALB ~\$$16/mo, EC2 nodes. See docs/finops.md."
	@echo "   Regions to apply: $(ACTIVE_REGIONS)"
	@echo "   Run 'make teardown' at session end."
	@echo "============================================================"
