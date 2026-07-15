#!/bin/bash

set -e

source ../config.sh
source ../utils.sh

# =============================================================================
# APP TEARDOWN - safely decommissions a client app. Each app has TWO isolated
# R2 tokens (see vps-rails-app-add.sh): a backup-bucket token whose id is
# stored in /etc/litestream.yml, and an upload-bucket token that only ever
# lived in the Rails app's own credentials - IaCarus keeps no local record of
# it. This script:
#   1. pulls the app's Litestream block from /etc/litestream.yml to recover
#      the backup token's id (stored as the access-key-id) and bucket name,
#   2. derives the app slug from that bucket name to reconstruct the sibling
#      upload bucket/token names (no separate registry file needed),
#   3. revokes BOTH scoped R2 tokens in Cloudflare (by id, and by name),
#   4. deregisters the database from Litestream.
# R2 BUCKETS AND THEIR DATA ARE RETAINED - only the live credentials are
# killed and replication stops. Delete buckets separately via 'make bucket-delete'.
# Usage: make vps-app-remove
# =============================================================================

# 1. Check configuration variables availability
echo -e "\n${C_INFO}🔍 Checking Pre-requisites...${C_RESET}"
if [[ -z "$CF_API_BEARER_TOKEN" || -z "$CF_ACCOUNT_ID" ]]; then
    echo -e "${C_ERROR}❌ Error: Missing CF_API_BEARER_TOKEN or CF_ACCOUNT_ID.${C_RESET}"
    exit 1
fi

# 2. Get Server Details (Sets $SELECTED_NAME)
select_server_interactive

# 3. Pre-Flight Connection Check
if ! check_ssh_access "$SELECTED_NAME"; then
    exit 1
fi

# 4. Collect App Label
echo -e "\n${C_INFO}🗑️  Decommissioning a client app on ${C_RESET}${C_HIGH}$SELECTED_NAME${C_RESET}${C_INFO}...${C_RESET}"

echo -n ">  App label to remove (as given to 'make vps-app-add'): "
read APP_LABEL

if [ -z "$APP_LABEL" ]; then
    echo -e "${C_ERROR}❌ An app label is required. Aborted.${C_RESET}"
    exit 1
fi

# 5. Verify the Entry Exists
echo -e "${C_INFO}🔍 Checking for '$APP_LABEL' on $SELECTED_NAME...${C_RESET}"
if ! ssh -q "$SELECTED_NAME" "sudo grep -qF -- '  # $APP_LABEL' /etc/litestream.yml"; then
    echo -e "${C_ERROR}❌ '$APP_LABEL' is not registered on $SELECTED_NAME. Aborted.${C_RESET}"
    exit 1
fi

# 6. Recover the backup token id + bucket (stored in the block itself), then
#    derive the app slug from the bucket name to reconstruct the sibling
#    upload bucket/token names - no separate registry file needed.
echo -e "${C_INFO}🔎 Recovering the scoped token id from /etc/litestream.yml...${C_RESET}"
BKP_TOKEN_ID=$(litestream_get_access_key "$SELECTED_NAME" "$APP_LABEL")
BKP_BUCKET=$(litestream_get_bucket "$SELECTED_NAME" "$APP_LABEL")

if [ -z "$BKP_TOKEN_ID" ]; then
    echo -e "${C_WARN}⚠️  Could not read an access-key-id for '$APP_LABEL' - will skip backup token revocation.${C_RESET}"
else
    echo -e "${C_INFO}   Backup token id (Access Key ID): ${C_RESET}${C_HIGH}$BKP_TOKEN_ID${C_RESET}"
fi

UPL_TOKEN_NAME=""
if [[ -n "$BKP_BUCKET" && "$BKP_BUCKET" == "${CF_R2_BUCKET_BASE_NAME}"*"-bkp" ]]; then
    APP_SLUG="${BKP_BUCKET#"$CF_R2_BUCKET_BASE_NAME"}"
    APP_SLUG="${APP_SLUG%-bkp}"
    UPL_BUCKET="${CF_R2_BUCKET_BASE_NAME}${APP_SLUG}-upl"
    UPL_TOKEN_NAME="iacarus-${APP_SLUG}-upl"
    echo -e "${C_INFO}   Upload-bucket token to revoke: ${C_RESET}${C_HIGH}$UPL_TOKEN_NAME${C_RESET}${C_INFO} (bucket '$UPL_BUCKET' is NOT deleted)${C_RESET}"
else
    echo -e "${C_WARN}⚠️  Could not derive an app slug from bucket '$BKP_BUCKET' - will skip upload token revocation.${C_RESET}"
    echo -e "${C_WARN}    (Expected the 'make vps-app-add' naming convention: ${CF_R2_BUCKET_BASE_NAME}<slug>-bkp.)${C_RESET}"
fi

# 7. Safety Lock
echo -e "${C_WARN}⚠️  This revokes BOTH the backup and upload R2 credentials and stops backups for '$APP_LABEL'.${C_RESET}"
echo -e "${C_WARN}    R2 buckets and existing objects are NOT deleted.${C_RESET}"
echo -n ">  Type '$APP_LABEL' to confirm: "
read CONFIRMATION

if [ "$CONFIRMATION" != "$APP_LABEL" ]; then
    echo -e "${C_ERROR}❌ Name mismatch. Aborted.${C_RESET}"
    exit 1
fi

# 8. Revoke both scoped tokens in Cloudflare (best-effort: a legacy entry that
#    used the account-level S3 key won't be a deletable token id - warn & go on).
if [ -n "$BKP_TOKEN_ID" ]; then
    echo -e "${C_INFO}🔐 Revoking backup-bucket R2 token '$BKP_TOKEN_ID' in Cloudflare...${C_RESET}"
    if cloudflare_delete_token "$BKP_TOKEN_ID"; then
        echo -e "${C_SUCCESS}✅ Backup token revoked.${C_RESET}"
    else
        echo -e "${C_WARN}⚠️  Backup token not revoked (it may be a legacy/shared key, or already gone). Continuing.${C_RESET}"
    fi
fi

if [ -n "$UPL_TOKEN_NAME" ]; then
    echo -e "${C_INFO}🔐 Revoking upload-bucket R2 token '$UPL_TOKEN_NAME' in Cloudflare...${C_RESET}"
    if cloudflare_delete_token_by_name "$UPL_TOKEN_NAME"; then
        echo -e "${C_SUCCESS}✅ Upload token revoked (or was already gone).${C_RESET}"
    else
        echo -e "${C_WARN}⚠️  Upload token lookup/revocation failed. Continuing.${C_RESET}"
    fi
fi

# 9. Deregister the DB from Litestream & restart
echo -e "${C_INFO}📝 Removing '$APP_LABEL' from /etc/litestream.yml...${C_RESET}"
echo -e "${C_INFO}🔄 Restarting litestream...${C_RESET}"

if litestream_remove_db "$SELECTED_NAME" "$APP_LABEL"; then
    echo -e "${C_SUCCESS}✅ '$APP_LABEL' deregistered. Credential neutralized; R2 data retained.${C_RESET}"
else
    echo -e "${C_ERROR}❌ litestream failed to (re)start. Check 'journalctl -u litestream' on $SELECTED_NAME.${C_RESET}"
    exit 1
fi
