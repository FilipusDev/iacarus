include config.mk

# -----------------------------------------------------------------------------
# 🦅 IaCarus - CONTROL PLANE
# -----------------------------------------------------------------------------
#
# CONTROL PLANES
#   make setup       Local wizard + dependency check.
#   make hetzner     Hetzner VPS control plane (provision, health, Litestream).
#   make cloudflare  Cloudflare R2 control plane (bucket lifecycle).
#
# MULTI-TENANT APP ORCHESTRATOR (under `make hetzner`)
#   The high-level orchestrator provisions a whole client app in one shot -
#   `make hetzner` then:
#     vps-app-add     Create a private backup + an app-facing upload R2
#                     bucket, mint TWO isolated bucket-scoped account-owned R2
#                     tokens (one per bucket - a compromised app can never
#                     reach the backup bucket), and wire the app's SQLite DB
#                     into Litestream on a chosen box.
#     vps-app-remove  Revoke both scoped tokens and deregister the DB (R2 data
#                     is retained).
# -----------------------------------------------------------------------------

help: ## Show this help message
	@echo -e "\n🦅 $(C_HIGH)IaCarus ${VERSION} - CONTROL PLANE$(C_RESET)"
	@echo "------------------------------------------------"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(firstword $(MAKEFILE_LIST)) | awk 'BEGIN {FS = ":.*?## "}; {printf "$(C_HIGH)%-20s$(C_RESET) %s\n", $$1, $$2}'
	@echo ""

setup: ## Run the setup script
	@./setup.sh

hetzner: ## Enter Hetzner Control Plane
	@$(MAKE) -C hetzner help

cloudflare: ## Enter Cloudflare Control Plane
	@$(MAKE) -C cloudflare help

.PHONY: help setup hetzner cloudflare
