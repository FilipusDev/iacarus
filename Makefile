include config.mk

# -----------------------------------------------------------------------------
# 🦅 IaCarus - CONTROL PLANE
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
