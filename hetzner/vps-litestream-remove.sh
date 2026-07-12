#!/bin/bash

set -e

source ../config.sh
source ../utils.sh

# 1. Get Server Details (Sets $SELECTED_NAME)
select_server_interactive

# 2. Pre-Flight Connection Check
if ! check_ssh_access "$SELECTED_NAME"; then
    exit 1
fi

# 3. Collect App Label
echo -e "\n${C_INFO}🗑️  Deregistering a SQLite DB from Litestream replication on ${C_RESET}${C_HIGH}$SELECTED_NAME${C_RESET}${C_INFO}...${C_RESET}"

echo -n ">  App label to remove (as given to 'make vps-litestream-add'): "
read APP_LABEL

if [ -z "$APP_LABEL" ]; then
    echo -e "${C_ERROR}❌ An app label is required. Aborted.${C_RESET}"
    exit 1
fi

# 4. Verify the Entry Exists
echo -e "${C_INFO}🔍 Checking for '$APP_LABEL' on $SELECTED_NAME...${C_RESET}"
if ! ssh -q "$SELECTED_NAME" "sudo grep -qF -- '  # $APP_LABEL' /etc/litestream.yml"; then
    echo -e "${C_ERROR}❌ '$APP_LABEL' is not registered on $SELECTED_NAME. Aborted.${C_RESET}"
    exit 1
fi

# 5. Safety Lock
echo -e "${C_WARN}⚠️  This stops backups for '$APP_LABEL' - existing R2 objects are NOT deleted.${C_RESET}"
echo -n ">  Type '$APP_LABEL' to confirm: "
read CONFIRMATION

if [ "$CONFIRMATION" != "$APP_LABEL" ]; then
    echo -e "${C_ERROR}❌ Name mismatch. Aborted.${C_RESET}"
    exit 1
fi

# 6. Remove the Entry & Restart Litestream
echo -e "${C_INFO}📝 Removing '$APP_LABEL' from /etc/litestream.yml...${C_RESET}"
echo -e "${C_INFO}🔄 Restarting litestream...${C_RESET}"

if litestream_remove_db "$SELECTED_NAME" "$APP_LABEL"; then
    echo -e "${C_SUCCESS}✅ '$APP_LABEL' deregistered.${C_RESET}"
else
    echo -e "${C_ERROR}❌ litestream failed to (re)start. Check 'journalctl -u litestream' on $SELECTED_NAME.${C_RESET}"
    exit 1
fi
