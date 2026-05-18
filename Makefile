# =============================================================================
# Makefile — local quality gates for the AWS landing-zone account fabric
# =============================================================================
# CI (.github/workflows/) is the canonical apply path: terraform-plan.yml on
# PRs, terraform-apply-baseline.yml on merge to main. This Makefile only wraps
# the local pre-commit checks. The account fabric has no cost-incurring layers
# and no per-region orchestration, so there are no apply / teardown /
# cold-apply targets here.
#
# Quick start:
#   make dev-setup     # install the pinned toolchain into ./bin
#   make help          # list targets
# =============================================================================

CONFIG := config/landing-zone.yaml
BIN    := $(CURDIR)/bin

# Pinned tools (./bin) take precedence over anything on the host.
export PATH := $(BIN):$(PATH)

.DEFAULT_GOAL := help
.PHONY: help dev-setup fmt config-check _check-config

help: ## Show this help
	@echo "Landing zone — local quality gates"
	@echo
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

dev-setup: ## Install the pinned toolchain (tflint, gitleaks, kubeconform, jq) into ./bin
	./scripts/install-tools.sh

fmt: ## terraform fmt across the whole tree
	terraform fmt -recursive terraform/

config-check: _check-config ## Validate config/landing-zone.yaml + sync backend.tf files
	python3 scripts/validate-config.py
	./scripts/configure-backends.sh

_check-config:
	@test -f $(CONFIG) || { \
	  echo "ERROR: $(CONFIG) not found. Copy config/landing-zone.example.yaml and fill it in."; exit 1; }
