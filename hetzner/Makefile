include ../config.mk

# -----------------------------------------------------------------------------
# | ☁  HETZNER | 🦅 IaCarus - CONTROL PLANE
# -----------------------------------------------------------------------------

SHELL := /bin/bash

PROVISION_SCRIPT         := ./vps-provision.sh
DESTROY_SCRIPT           := ./vps-destroy.sh
LIST_SCRIPT              := ./vps-list.sh
HEALTH_SCRIPT            := ./vps-health-check.sh
SMOKE_SCRIPT             := ./vps-cf-tunnel-smoke_test.sh
LITESTREAM_SCRIPT        := ./vps-litestream-add.sh
LITESTREAM_REMOVE_SCRIPT := ./vps-litestream-remove.sh
LITESTREAM_SMOKE_SCRIPT  := ./vps-litestream-smoke_test.sh
APP_ADD_SCRIPT           := ./vps-rails-app-add.sh
APP_REMOVE_SCRIPT        := ./vps-rails-app-remove.sh

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

vps-litestream-add: ## Register a new SQLite DB for Litestream backup replication
	@$(LITESTREAM_SCRIPT)

vps-litestream-remove: ## Deregister a SQLite DB from Litestream backup replication
	@$(LITESTREAM_REMOVE_SCRIPT)

vps-litestream-smoke: ## Run an end-to-end Litestream replication smoke test
	@$(LITESTREAM_SMOKE_SCRIPT)

vps-app-add: ## Orchestrate a client app: R2 buckets + 2 isolated scoped tokens + Litestream
	@$(APP_ADD_SCRIPT)

vps-app-remove: ## Decommission a client app: revoke both tokens + deregister Litestream
	@$(APP_REMOVE_SCRIPT)

.PHONY: help vps-new vps-down vps-list vps-check-health vps-smoke-tunnel vps-litestream-add vps-litestream-remove vps-litestream-smoke vps-app-add vps-app-remove
