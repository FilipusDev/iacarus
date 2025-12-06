include ../config.mk

# -----------------------------------------------------------------------------
# | ☁  HETZNER | 🦅 IaCarus - CONTROL PLANE
# -----------------------------------------------------------------------------

SHELL := /bin/bash

PROVISION_SCRIPT := ./vps-provision.sh
DESTROY_SCRIPT   := ./vps-destroy.sh
LIST_SCRIPT      := ./vps-list.sh
HEALTH_SCRIPT    := ./vps-health-check.sh
SMOKE_SCRIPT     := ./vps-cf-tunnel-smoke_test.sh

help: ## Show this help message
	@echo -e "\n$(C_HIGH)| ☁  HETZNER | 🦅 IaCarus ${VERSION} - CONTROL PLANE$(C_RESET)"
	@echo "------------------------------------------------"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(firstword $(MAKEFILE_LIST)) | awk 'BEGIN {FS = ":.*?## "}; {printf "$(C_HIGH)%-20s$(C_RESET) %s\n", $$1, $$2}'
	@echo ""

vps-new:  ## Provision a new server
	@$(PROVISION_SCRIPT)

vps-down: ## Destroy a server (Interactive)
	@$(DESTROY_SCRIPT)

vps-list: ## List active servers
	@$(LIST_SCRIPT)

vps-check-health: ## Run health check
	@$(HEALTH_SCRIPT)

vps-smoke-tunnel: ## Run smoke test setting up a Cloud Flare Tunnel
	@$(SMOKE_SCRIPT)

.PHONY: help vps-new vps-down vps-list vps-check-health vps-smoke-tunnel
