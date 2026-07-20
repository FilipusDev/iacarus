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
HW_SCRIPT       := ./mon-hw.sh
REMOTE_SCRIPT   := ./mon-remote.sh
PIN_SCRIPT      := ./mon-glances-pin.sh

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

mon-hw: ## Live hardware board across the fleet (glances over SSH tunnels)
	@$(HW_SCRIPT)

mon-glances-pin: ## Pin this viewer's glances to the fleet's version (venv; run once)
	@$(PIN_SCRIPT)

mon-apps: ## Live app liveness + latency board (Ctrl-C to stop)
	@$(APPS_SCRIPT)

mon-apps-once: ## One pass over the apps, then exit (non-zero if anything is down)
	@$(APPS_SCRIPT) --once

# --- Same boards, run ON the always-on mon box ------------------------------
# Identical output; the difference is WHERE the checks originate (next to the
# fleet, not from your laptop). Latency figures will differ accordingly.

mon-box-hw: ## Hardware board, run on the mon box
	@$(REMOTE_SCRIPT) mon-hw

mon-box-apps: ## App board, run on the mon box
	@$(REMOTE_SCRIPT) mon-apps

mon-box-apps-once: ## One app pass on the mon box (non-zero if anything is down)
	@$(REMOTE_SCRIPT) mon-apps-once --no-tty

.PHONY: help mon-check mon-list mon-register mon-hw mon-glances-pin mon-apps mon-apps-once mon-box-hw mon-box-apps mon-box-apps-once
