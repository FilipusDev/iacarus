include ../config.mk

# -----------------------------------------------------------------------------
# | 📡 MON | 🦅 IaCarus - CONTROL PLANE
# -----------------------------------------------------------------------------
#
# The viewer is STATELESS and PORTABLE: monitoring data lives on the app boxes,
# this is a thin client that reads it. The same targets run from a laptop or a
# dedicated mon box - where it runs is a runtime choice, never a code fork.
# 'make mon-check' reports which capabilities the current machine actually has.
# -----------------------------------------------------------------------------

SHELL := /bin/bash

CHECK_SCRIPT    := ./mon-check.sh
LIST_SCRIPT     := ./mon-list.sh
REGISTER_SCRIPT := ./mon-register.sh
APPS_SCRIPT     := ./mon-apps.sh

help: ## Show this help message
	@echo -e "\n$(C_HIGH)| 📡 MON | 🦅 IaCarus ${VERSION} - CONTROL PLANE$(C_RESET)"
	@echo "------------------------------------------------"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(firstword $(MAKEFILE_LIST)) | awk 'BEGIN {FS = ":.*?## "}; {printf "$(C_HIGH)%-20s$(C_RESET) %s\n", $$1, $$2}'
	@echo ""

mon-check: ## Report viewer readiness: context, tooling, registry, box reachability
	@$(CHECK_SCRIPT)

mon-list: ## List the registered apps (offline - no network, no credentials)
	@$(LIST_SCRIPT)

mon-register: ## Hand-register an existing app (backfill; derives what it can)
	@$(REGISTER_SCRIPT)

mon-apps: ## Live app liveness + latency board (Ctrl-C to stop)
	@$(APPS_SCRIPT)

mon-apps-once: ## One pass over the apps, then exit (non-zero if anything is down)
	@$(APPS_SCRIPT) --once

.PHONY: help mon-check mon-list mon-register mon-apps mon-apps-once
