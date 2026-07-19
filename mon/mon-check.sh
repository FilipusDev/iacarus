#!/bin/bash

set -e

# Sourced with a guard: run from anywhere but mon/ and these paths resolve
# outside the repo and fail SILENTLY (the ERR trap lives in utils.sh, which
# hasn't loaded yet either) - leaving the script running with no config and no
# helpers. For a monitoring tool that surfaces as a false "nothing to watch"
# all-clear, which is worse than any error. Fail loudly instead.
if ! source ../config.sh 2>/dev/null || ! source ../utils.sh 2>/dev/null; then
    echo "❌ Could not load ../config.sh + ../utils.sh."
    echo "   Run this from the mon/ directory, or use the Makefile target."
    exit 1
fi

# =============================================================================
# 📡 MON - viewer readiness + execution context (SPRINT B1)
#
# Answers "can this machine drive the fleet, and what will it be able to show?"
# The viewer is stateless and portable, so the SAME code runs from a laptop or a
# dedicated mon box - this target reports which capabilities are actually
# present here, rather than assuming. Strictly read-only.
# Usage: make mon-check
# =============================================================================

echo -e "\n${C_INFO}📡 Mon viewer readiness...${C_RESET}"

# 1. Execution context. 'operator' can enumerate the Hetzner fleet live;
#    'viewer' works off the registry + ssh config alone. Neither is degraded for
#    app checks (B4 needs only curl) - it bounds hardware discovery (B2).
CONTEXT=$(mon_context)

echo ""
if [ "$CONTEXT" = "operator" ]; then
    echo -e "${C_SUCCESS}✅ Context: operator${C_RESET} ${C_INFO}(hcloud answers - fleet is discoverable live)${C_RESET}"
else
    echo -e "${C_INFO}ℹ️  Context: viewer${C_RESET} ${C_INFO}(no usable hcloud - working from the registry + ssh config)${C_RESET}"
fi

# 2. Tooling. curl + jq are what the app viewer (B4) actually needs; ssh is what
#    the hardware viewer (B2) needs. Report them separately so a laptop without
#    infra creds still gets a clear "apps will work" verdict.
echo ""
echo -e "${C_INFO}🔧 Tooling${C_RESET}"
MISSING=0
for CMD in curl jq ssh; do
    if command -v "$CMD" > /dev/null 2>&1; then
        echo -e "   ${C_SUCCESS}✅ $CMD${C_RESET}"
    else
        echo -e "   ${C_ERROR}❌ $CMD (required)${C_RESET}"
        MISSING=1
    fi
done

# 3. Bail before reading anything. Everything below needs jq, so continuing
#    would only leak raw "command not found" noise over the real verdict.
if [ "$MISSING" -ne 0 ]; then
    echo ""
    echo -e "${C_ERROR}❌ Missing required tooling - run 'make setup' from the project root.${C_RESET}"
    echo ""
    exit 1
fi

# 4. Registry presence.
echo ""
echo -e "${C_INFO}📒 Registry${C_RESET}"
COUNT=$(mon_registry_list | wc -l)

if [ ! -f "$MON_REGISTRY" ]; then
    echo -e "   ${C_WARN}⚠️  $MON_REGISTRY does not exist yet${C_RESET}"
    echo -e "   ${C_INFO}   'make vps-app-add' creates it; 'make mon-register' backfills.${C_RESET}"
elif [ "$COUNT" -eq 0 ]; then
    echo -e "   ${C_WARN}⚠️  registry is empty - nothing to watch${C_RESET}"
else
    echo -e "   ${C_SUCCESS}✅ $COUNT app(s) registered${C_RESET}"
fi

# 5. SSH reachability per distinct box in the registry. This is the hardware
#    path (B2) - apps are checked over their public URL and need none of it.
#    BatchMode so a box needing a passphrase/password fails fast instead of
#    hanging the report on a prompt.
if [ "$COUNT" -gt 0 ]; then
    echo ""
    echo -e "${C_INFO}🔌 Box reachability (SSH - needed for hardware views)${C_RESET}"

    #    The -n matters: this loop's stdin IS the box list, and without it ssh
    #    would consume the remaining boxes and silently check only the first.
    while read -r BOX; do
        if ssh -q -n -o BatchMode=yes -o ConnectTimeout=8 "$BOX" true > /dev/null 2>&1; then
            echo -e "   ${C_SUCCESS}✅ $BOX${C_RESET}"
        else
            echo -e "   ${C_WARN}⚠️  $BOX unreachable${C_RESET} ${C_INFO}(check your ~/.ssh/config alias)${C_RESET}"
        fi
    done < <(mon_registry_list | jq -r '.box' | sort -u)
fi

# 6. Verdict.
echo ""
echo -e "${C_SUCCESS}✅ Viewer is ready.${C_RESET} ${C_INFO}Try: ${C_RESET}${C_HIGH}make mon-list${C_RESET}"
echo ""
