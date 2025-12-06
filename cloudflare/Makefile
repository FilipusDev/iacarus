include ../config.mk

# -----------------------------------------------------------------------------
# | 🛜 CLOUDFLARE | 🦅 IaCarus - CONTROL PLANE
# -----------------------------------------------------------------------------

SHELL := /bin/bash

LIST_SCRIPT      := ./r2-list.sh
PROVISION_SCRIPT := ./r2-provision.sh
DESTROY_SCRIPT   := ./r2-destroy.sh
SMOKE_SCRIPT     := ./r2-smoke_test.sh


help: ## Show this help message
	@echo -e "\n$(C_HIGH)| 🛜 CLOUDFLARE | 🦅 IaCarus ${VERSION} - CONTROL PLANE$(C_RESET)"
	@echo "------------------------------------------------"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(firstword $(MAKEFILE_LIST)) | awk 'BEGIN {FS = ":.*?## "}; {printf "$(C_HIGH)%-20s$(C_RESET) %s\n", $$1, $$2}'
	@echo ""

bucket-new:  ## Provision a new R2 bucket
	@$(PROVISION_SCRIPT)

bucket-delete: ## Delete R2 objects or buckets (Interactive)
	@$(DESTROY_SCRIPT)

bucket-list: ## List all R2 buckets
	@$(LIST_SCRIPT)

bucket-smoke: ## Run smoke test a R2 bucket
	@$(SMOKE_SCRIPT)

.PHONY: help bucket-new bucket-down bucket-list bucket-smoke
