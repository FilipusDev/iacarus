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
# 📡 MON - list the registered apps (SPRINT B1)
#
# Pure read of mon/registry.json. NO network, NO ssh, NO credentials - this is
# the one mon target that works on a plane. B4 grows the live health columns on
# top of exactly this iteration.
# Usage: make mon-list
# =============================================================================

echo -e "\n${C_INFO}📡 Registered apps${C_RESET} ${C_INFO}($MON_REGISTRY)${C_RESET}"

# 1. An absent or empty registry is a normal state (fresh clone, nothing added
#    yet), not an error - point at the fix instead of failing.
COUNT=$(mon_registry_list | wc -l)

if [ "$COUNT" -eq 0 ]; then
    echo -e "${C_WARN}🤷 No apps registered yet.${C_RESET}"
    echo -e "${C_INFO}   'make vps-app-add' registers new apps automatically.${C_RESET}"
    echo -e "${C_INFO}   For an app that already exists, run: ${C_RESET}${C_HIGH}make mon-register${C_RESET}"
    echo ""
    exit 0
fi

# 2. Table. Widths are derived from the data so long slugs don't wrap into an
#    unreadable mess on a narrow terminal.
W_NAME=$(mon_registry_list | jq -r '.name'     | awk '{ if (length > m) m = length } END { print (m > 4 ? m : 4) }')
W_SLUG=$(mon_registry_list | jq -r '.app_slug' | awk '{ if (length > m) m = length } END { print (m > 8 ? m : 8) }')
W_BOX=$(mon_registry_list  | jq -r '.box'      | awk '{ if (length > m) m = length } END { print (m > 3 ? m : 3) }')

printf "\n${C_HIGH}%-${W_NAME}s  %-${W_SLUG}s  %-${W_BOX}s  %s${C_RESET}\n" "NAME" "APP SLUG" "BOX" "HEALTH URL"

while read -r ROW; do
    NAME=$(echo "$ROW" | jq -r '.name')
    SLUG=$(echo "$ROW" | jq -r '.app_slug')
    BOX=$(echo "$ROW" | jq -r '.box')
    URL="$(echo "$ROW" | jq -r '.base_url')$(echo "$ROW" | jq -r '.health_path')"

    printf "%-${W_NAME}s  %-${W_SLUG}s  %-${W_BOX}s  %s\n" "$NAME" "$SLUG" "$BOX" "$URL"
done < <(mon_registry_list)

echo ""
echo -e "${C_INFO}$COUNT app(s) registered.${C_RESET}"
echo ""
