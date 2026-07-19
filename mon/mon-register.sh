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
# 📡 MON - hand-register an existing app (SPRINT B0 backfill / B1)
#
# 'make vps-app-add' registers apps automatically from now on. This covers the
# apps that already existed before the registry did - and any hand-fix.
#
# It DERIVES what it can rather than making you retype it:
#   base_url <- the upl bucket's live CORS policy (needs R2 creds)
#   label    <- the labels present in /etc/litestream.yml on the box (needs SSH)
# Every derived value is offered as a default you can override, and each
# derivation is optional: without creds it simply falls back to a prompt, so
# this still works from a credential-less mon box.
#
# Idempotent - re-registering the same app_slug updates its row in place.
# Usage: make mon-register        (interactive)
#        ./mon-register.sh <APP_SLUG>
# =============================================================================

echo -e "\n${C_INFO}📡 Register an existing app for monitoring...${C_RESET}"

# 1. App slug - the registry key. Fleet-unique, and what the R2 buckets and
#    scoped tokens are already named after.
APP_SLUG=$1
if [ -z "$APP_SLUG" ]; then
    echo -n ">  App slug (e.g. 'tcg-2026-01-mpl-prd'): "
    read APP_SLUG
fi
if [ -z "$APP_SLUG" ]; then
    echo -e "${C_ERROR}❌ An app slug is required. Aborted.${C_RESET}"
    exit 1
fi

# 2. Box. With hcloud creds, pick from the live fleet; otherwise type the ssh
#    alias (a mon box knows its aliases even when it holds no Hetzner creds).
CONTEXT=$(mon_context)

if [ "$CONTEXT" = "operator" ]; then
    select_server_interactive
    BOX="$SELECTED_NAME"
else
    echo -e "${C_INFO}ℹ️  No usable hcloud here - type the box's ssh alias.${C_RESET}"
    echo -n ">  Box (ssh alias): "
    read BOX
fi
if [ -z "$BOX" ]; then
    echo -e "${C_ERROR}❌ A box is required. Aborted.${C_RESET}"
    exit 1
fi

# 3. Label - must match what litestream recorded, because that is the pair
#    ('box' + 'label') vps-app-remove will later use to find this row. Read the
#    labels off the box so a typo can't silently orphan the entry.
#    NOTE the -n on both ssh calls: without it ssh forwards our stdin to the
#    remote command and eats the answers meant for the prompts below.
LABELS=""
if ssh -q -n -o BatchMode=yes -o ConnectTimeout=8 "$BOX" true > /dev/null 2>&1; then
    LABELS=$(ssh -q -n "$BOX" "sudo grep -E '^  # ' /etc/litestream.yml 2>/dev/null | sed 's/^  # //'" 2>/dev/null || true)
fi

if [ -n "$LABELS" ]; then
    echo -e "\n${C_INFO}🏷️  Litestream labels on ${C_RESET}${C_HIGH}$BOX${C_RESET}${C_INFO}:${C_RESET}"

    PS3="Enter number (or 'q' to quit): "
    select ITEM in $LABELS; do
        [[ "$REPLY" == "q" ]] && echo "Aborted." && exit 0
        if [ -n "$ITEM" ]; then
            APP_LABEL="$ITEM"
            break
        fi
        echo "Invalid selection."
    done
else
    echo -e "${C_WARN}⚠️  Could not read litestream labels from $BOX - type it by hand.${C_RESET}"
    echo -e "${C_WARN}   It MUST match the '# <label>' comment in /etc/litestream.yml,${C_RESET}"
    echo -e "${C_WARN}   or 'make vps-app-remove' won't find this row later.${C_RESET}"
    echo -n ">  App label: "
    read APP_LABEL
fi
if [ -z "$APP_LABEL" ]; then
    echo -e "${C_ERROR}❌ An app label is required. Aborted.${C_RESET}"
    exit 1
fi

# 4. base_url. The upl bucket's CORS policy already records the app's browser
#    origin, so read it back instead of asking. NOTE this is the *upload* origin
#    - correct whenever the app presigns uploads from the host it serves on,
#    which is the normal case, but confirm it at the prompt.
UPL_BUCKET="${CF_R2_BUCKET_BASE_NAME}${APP_SLUG}-upl"
DERIVED_URL=""

if [ -n "$CF_R2_S3_CLIENT_URL" ]; then
    echo -e "\n${C_INFO}🌐 Reading the CORS origin from '$UPL_BUCKET'...${C_RESET}"
    DERIVED_URL=$(aws s3api get-bucket-cors --bucket "$UPL_BUCKET" \
        --endpoint-url "$CF_R2_S3_CLIENT_URL" 2>/dev/null \
        | jq -r '.CORSRules[0].AllowedOrigins[0] // empty' 2>/dev/null || true)
fi

if [ -n "$DERIVED_URL" ]; then
    echo -e "${C_SUCCESS}✅ Found: ${C_RESET}${C_HIGH}$DERIVED_URL${C_RESET}"
    echo -n ">  Base URL [$DERIVED_URL]: "
    read BASE_URL
    BASE_URL="${BASE_URL:-$DERIVED_URL}"
else
    echo -e "${C_WARN}⚠️  No CORS origin readable - type the app's base URL.${C_RESET}"
    echo -n ">  Base URL (e.g. https://mpl.example.com): "
    read BASE_URL
fi
if [ -z "$BASE_URL" ]; then
    echo -e "${C_ERROR}❌ A base URL is required. Aborted.${C_RESET}"
    exit 1
fi

# 5. Remaining registry fields.
echo -n ">  Health endpoint path [/up]: "
read HEALTH_PATH
HEALTH_PATH="${HEALTH_PATH:-/up}"

echo -n ">  Display name [$APP_LABEL]: "
read APP_NAME
APP_NAME="${APP_NAME:-$APP_LABEL}"

# 6. Prove the endpoint answers BEFORE recording it - a registry row pointing at
#    a dead path is worse than no row, because it looks watched. Non-fatal: the
#    app may legitimately be down right now, so confirm and carry on.
echo -e "\n${C_INFO}🩺 Checking ${C_RESET}${C_HIGH}${BASE_URL}${HEALTH_PATH}${C_RESET}${C_INFO}...${C_RESET}"
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${BASE_URL}${HEALTH_PATH}" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "200" ]; then
    echo -e "${C_SUCCESS}✅ 200 OK.${C_RESET}"
else
    echo -e "${C_WARN}⚠️  Got '$HTTP_CODE' (wanted 200).${C_RESET}"
    echo -n ">  Register anyway? (y/N): "
    read PROCEED
    if [[ ! "$PROCEED" =~ ^[Yy]$ ]]; then
        echo -e "${C_INFO}Aborted - nothing written.${C_RESET}"
        exit 0
    fi
fi

# 7. Upsert.
echo -e "\n${C_INFO}📡 Writing '$APP_SLUG' to the registry...${C_RESET}"

if mon_registry_add "$APP_SLUG" "$BOX" "$APP_LABEL" "$BASE_URL" "$HEALTH_PATH" "$APP_NAME"; then
    echo -e "${C_SUCCESS}✅ Registered.${C_RESET}"
else
    echo -e "${C_ERROR}❌ Could not write $MON_REGISTRY. Aborted.${C_RESET}"
    exit 1
fi

echo ""
echo -e "${C_SUCCESS}------------------------------------------------${C_RESET}"
echo -e "${C_SUCCESS}📡 MONITORED: ${C_RESET}${C_HIGH}$APP_SLUG${C_RESET}"
echo -e "${C_SUCCESS}------------------------------------------------${C_RESET}"
echo -e "   Display name : ${C_HIGH}$APP_NAME${C_RESET}"
echo -e "   Box          : ${C_HIGH}$BOX${C_RESET} ${C_INFO}(label '$APP_LABEL')${C_RESET}"
echo -e "   Health check : ${C_HIGH}${BASE_URL}${HEALTH_PATH}${C_RESET}"
echo -e "${C_SUCCESS}------------------------------------------------${C_RESET}"
echo ""
