include ../config.mk

# -----------------------------------------------------------------------------
# | ☁  HETZNER | 🦅 IaCarus - CONTROL PLANE
# -----------------------------------------------------------------------------

SHELL := /bin/bash

PROVISION_SCRIPT := ./vps-provision.sh
DESTROY_SCRIPT   := ./vps-destroy.sh
HEALTH_SCRIPT    := ./vps-health-check.sh
SMOKE_SCRIPT     := ./vps-cf-tunnel-smoke_test.sh

help: ## Show this help message
	@echo -e "\n$(C_HIGH)| ☁  HETZNER | 🦅 IaCarus - CONTROL PLANE$(C_RESET)"
	@echo "------------------------------------------------"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(firstword $(MAKEFILE_LIST)) | awk 'BEGIN {FS = ":.*?## "}; {printf "$(C_HIGH)%-20s$(C_RESET) %s\n", $$1, $$2}'
	@echo ""

vps-new:  ## Provision a new server
	@$(PROVISION_SCRIPT)

vps-down: ## Destroy a server (Interactive)
	@$(DESTROY_SCRIPT)

vps-list: ## List active servers
	@echo -e "$(C_INFO)🔍 Fetching server list...$(C_RESET)"
	@hcloud server list -o columns=id,name,ipv4,datacenter,status

vps-check-heath: ## Run health check
	@$(HEALTH_SCRIPT)

vps-smoke-tunnel: ## Run smoke test setting up a Cloud Flare Tunnel
	@$(SMOKE_SCRIPT)

.PHONY: help vps-new vps-down vps-list vps-check-heath vps-smoke-tunnel
