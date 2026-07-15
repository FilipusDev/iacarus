#!/bin/bash

set -e

source ../config.sh
source ../utils.sh

# =============================================================================
# APP ORCHESTRATOR - provisions a client app end-to-end:
#   1. two R2 buckets (private backup + public upload)
#   2. a bucket-scoped, account-owned R2 token pair (mint via Cloudflare API)
#   3. a Litestream replication entry on a chosen Hetzner box, wired to the
#      freshly minted scoped credentials.
# Usage: make vps-app-add        (fully interactive)
#        ./vps-rails-app-add.sh <PROJECT_CODE> <APP_LABEL> <ENVIRONMENT>
# =============================================================================

# 1. Check configuration variables availability
echo -e "\n${C_INFO}🔍 Checking Pre-requisites...${C_RESET}"
if [[ -z "$CF_R2_S3_CLIENT_URL" || -z "$CF_R2_S3_CLIENT_ACCESS_KEY_ID" || -z "$CF_R2_S3_CLIENT_SECRET_ACCESS_KEY" \
   || -z "$CF_API_BEARER_TOKEN" || -z "$CF_ACCOUNT_ID" || -z "$CF_R2_BUCKET_BASE_NAME" ]]; then
    echo -e "${C_ERROR}❌ Error: Missing configuration variables (check R2 S3 keys + CF_API_BEARER_TOKEN + CF_ACCOUNT_ID).${C_RESET}"
    exit 1
fi

# 2. Collect App Identity (positional args override prompts)
echo -e "\n${C_INFO}🧩 Client app identity...${C_RESET}"

PROJECT_CODE=$1
if [ -z "$PROJECT_CODE" ]; then
    echo -n ">  Project code (e.g. 'ccg-2026-0001'): "
    read PROJECT_CODE
fi
if [ -z "$PROJECT_CODE" ]; then
    echo -e "${C_ERROR}❌ A project code is required. Aborted.${C_RESET}"
    exit 1
fi

APP_LABEL=$2
if [ -z "$APP_LABEL" ]; then
    echo -n ">  App label (e.g. 'mpl'): "
    read APP_LABEL
fi
if [ -z "$APP_LABEL" ]; then
    echo -e "${C_ERROR}❌ An app label is required. Aborted.${C_RESET}"
    exit 1
fi

ENVIRONMENT=$3
if [ -z "$ENVIRONMENT" ]; then
    echo -n ">  Environment [prd]: "
    read ENVIRONMENT
    ENVIRONMENT=${ENVIRONMENT:-prd}
fi

# 3. Compute the golden-format bucket names
APP_SLUG="${PROJECT_CODE}-${APP_LABEL}-${ENVIRONMENT}"
BKP_BUCKET="${CF_R2_BUCKET_BASE_NAME}${APP_SLUG}-bkp"
UPL_BUCKET="${CF_R2_BUCKET_BASE_NAME}${APP_SLUG}-upl"
TOKEN_NAME="iacarus-${APP_SLUG}"

echo -e "${C_INFO}   Backup (private): ${C_RESET}${C_HIGH}$BKP_BUCKET${C_RESET}"
echo -e "${C_INFO}   Upload (public):  ${C_RESET}${C_HIGH}$UPL_BUCKET${C_RESET}"

# 4. Create BOTH buckets in Cloudflare R2 (idempotent - skip if present)
for BUCKET in "$BKP_BUCKET" "$UPL_BUCKET"; do
    echo -e "${C_INFO}🔍 Checking if ${C_RESET}${C_HIGH}$BUCKET${C_RESET}${C_INFO} exists...${C_RESET}"
    if aws s3api head-bucket --bucket "$BUCKET" --endpoint-url "$CF_R2_S3_CLIENT_URL" > /dev/null 2>&1; then
        echo -e "${C_WARN}⚠️  Bucket '$BUCKET' already exists. Skipping creation.${C_RESET}"
    else
        echo -e "${C_INFO}🚰 Creating bucket '$BUCKET'...${C_RESET}"
        aws s3api create-bucket --bucket "$BUCKET" --endpoint-url "$CF_R2_S3_CLIENT_URL" > /dev/null
        echo -e "${C_SUCCESS}✅ Bucket created successfully!${C_RESET}"
    fi
done

# 5. Get Server Details (Sets $SELECTED_NAME)
select_server_interactive

# 6. Pre-Flight Connection Check
if ! check_ssh_access "$SELECTED_NAME"; then
    exit 1
fi

# 7. Collect the persistent DB location inside its Docker named volume
echo -e "\n${C_INFO}🗄️  Litestream target on ${C_RESET}${C_HIGH}$SELECTED_NAME${C_RESET}${C_INFO}...${C_RESET}"
echo -n ">  Full path to the SQLite DB inside its Docker volume (e.g. /var/lib/docker/volumes/${APP_LABEL}_data/_data/production.sqlite3): "
read DB_PATH

if [ -z "$DB_PATH" ]; then
    echo -e "${C_ERROR}❌ A DB path is required. Aborted.${C_RESET}"
    exit 1
fi

# 8. Guard against a duplicate registration BEFORE minting any credential
#    (so an aborted run never leaves an orphan token behind in Cloudflare).
echo -e "${C_INFO}🔍 Checking for an existing entry on $SELECTED_NAME...${C_RESET}"
if ssh -q "$SELECTED_NAME" "sudo grep -qF -- 'path: $DB_PATH' /etc/litestream.yml"; then
    echo -e "${C_ERROR}❌ '$DB_PATH' is already registered on $SELECTED_NAME. Aborted.${C_RESET}"
    exit 1
fi
if ssh -q "$SELECTED_NAME" "sudo grep -qF -- '  # $APP_LABEL' /etc/litestream.yml"; then
    echo -e "${C_ERROR}❌ Label '$APP_LABEL' is already registered on $SELECTED_NAME. Aborted.${C_RESET}"
    exit 1
fi

# 9. Mint TWO isolated, single-bucket-scoped tokens - NOT one token shared
#    across both buckets. This keeps them genuinely isolated: the credential
#    handed to the Rails app (upload bucket) can never reach the backup
#    bucket that Litestream depends on, and vice-versa.
BKP_TOKEN_NAME="${TOKEN_NAME}-bkp"
UPL_TOKEN_NAME="${TOKEN_NAME}-upl"

echo -e "${C_INFO}🔐 Minting scoped R2 token '${C_RESET}${C_HIGH}$BKP_TOKEN_NAME${C_RESET}${C_INFO}' (backup bucket only)...${C_RESET}"
if ! cloudflare_create_scoped_token "$BKP_TOKEN_NAME" "$BKP_BUCKET"; then
    echo -e "${C_ERROR}❌ Could not mint the backup-bucket token. Aborted.${C_RESET}"
    exit 1
fi
BKP_TOKEN_ID="$CF_SCOPED_TOKEN_ID"
BKP_ACCESS_KEY_ID="$CF_SCOPED_ACCESS_KEY_ID"
BKP_SECRET_ACCESS_KEY="$CF_SCOPED_SECRET_ACCESS_KEY"
echo -e "${C_SUCCESS}✅ Token minted. Access Key ID: ${C_RESET}${C_HIGH}$BKP_ACCESS_KEY_ID${C_RESET}"

echo -e "${C_INFO}🔐 Minting scoped R2 token '${C_RESET}${C_HIGH}$UPL_TOKEN_NAME${C_RESET}${C_INFO}' (upload bucket only)...${C_RESET}"
if ! cloudflare_create_scoped_token "$UPL_TOKEN_NAME" "$UPL_BUCKET"; then
    echo -e "${C_ERROR}❌ Could not mint the upload-bucket token - rolling back the backup token...${C_RESET}"
    cloudflare_delete_token "$BKP_TOKEN_ID" || echo -e "${C_ERROR}⚠️  Could not revoke '$BKP_TOKEN_ID' - delete it manually.${C_RESET}"
    exit 1
fi
UPL_TOKEN_ID="$CF_SCOPED_TOKEN_ID"
UPL_ACCESS_KEY_ID="$CF_SCOPED_ACCESS_KEY_ID"
UPL_SECRET_ACCESS_KEY="$CF_SCOPED_SECRET_ACCESS_KEY"
echo -e "${C_SUCCESS}✅ Token minted. Access Key ID: ${C_RESET}${C_HIGH}$UPL_ACCESS_KEY_ID${C_RESET}"

# 10. Register the DB for Litestream replication, wired to the BACKUP-scoped
#     credential only. If registration fails we roll back BOTH freshly minted
#     tokens (no orphan credentials left in Cloudflare).
echo -e "${C_INFO}📝 Appending '$APP_LABEL' ($DB_PATH -> $BKP_BUCKET) to /etc/litestream.yml...${C_RESET}"
echo -e "${C_INFO}🔄 Restarting litestream...${C_RESET}"

if litestream_register_db "$SELECTED_NAME" "$APP_LABEL" "$DB_PATH" "$BKP_BUCKET" "$CF_R2_S3_CLIENT_URL" "$BKP_ACCESS_KEY_ID" "$BKP_SECRET_ACCESS_KEY"; then
    echo -e "${C_SUCCESS}✅ '$APP_LABEL' registered and replicating to '$BKP_BUCKET'.${C_RESET}"
else
    echo -e "${C_ERROR}❌ litestream failed to (re)start - rolling back both minted tokens...${C_RESET}"
    cloudflare_delete_token "$BKP_TOKEN_ID" || echo -e "${C_ERROR}⚠️  Could not revoke '$BKP_TOKEN_ID' - delete it manually.${C_RESET}"
    cloudflare_delete_token "$UPL_TOKEN_ID" || echo -e "${C_ERROR}⚠️  Could not revoke '$UPL_TOKEN_ID' - delete it manually.${C_RESET}"
    echo -e "${C_ERROR}   Check 'journalctl -u litestream' on $SELECTED_NAME.${C_RESET}"
    exit 1
fi

# 11. Confirmation block (secrets stay masked here - see the copy-paste
#     snippet below for the one credential you actually need to hand off).
echo ""
echo -e "${C_SUCCESS}------------------------------------------------${C_RESET}"
echo -e "${C_SUCCESS}🎉 APP PROVISIONED: ${C_RESET}${C_HIGH}$APP_SLUG${C_RESET}"
echo -e "${C_SUCCESS}------------------------------------------------${C_RESET}"
echo -e "   Project code : ${C_HIGH}$PROJECT_CODE${C_RESET}"
echo -e "   App label    : ${C_HIGH}$APP_LABEL${C_RESET}"
echo -e "   Environment  : ${C_HIGH}$ENVIRONMENT${C_RESET}"
echo -e "   Server       : ${C_HIGH}$SELECTED_NAME${C_RESET}"
echo -e "   DB path      : ${C_HIGH}$DB_PATH${C_RESET}"
echo -e "${C_SUCCESS}------------------------------------------------${C_RESET}"
echo -e "   Backup bucket: ${C_HIGH}$BKP_BUCKET${C_RESET} ${C_INFO}(private, Litestream replica)${C_RESET}"
echo -e "     token      : ${C_HIGH}$BKP_TOKEN_NAME${C_RESET}"
echo -e "     access key : ${C_HIGH}$BKP_ACCESS_KEY_ID${C_RESET} ${C_INFO}(secret lives only in /etc/litestream.yml, 0600 root)${C_RESET}"
echo -e "   Upload bucket: ${C_HIGH}$UPL_BUCKET${C_RESET} ${C_INFO}(app-facing; see snippet below for its credential)${C_RESET}"
echo -e "     token      : ${C_HIGH}$UPL_TOKEN_NAME${C_RESET}"
echo -e "${C_SUCCESS}------------------------------------------------${C_RESET}"
echo -e "   ${C_WARN}Reminder:${C_RESET} if the R2 token has Client IP Address Filtering,"
echo -e "   allowlist $SELECTED_NAME so replication can reach R2."
echo -e "   ${C_WARN}Reminder:${C_RESET} '$UPL_BUCKET' is PRIVATE by default - if you need it"
echo -e "   reachable over the open internet, enable Public Access / bind a Custom"
echo -e "   Domain for it manually in the R2 dashboard (this is a one-time,"
echo -e "   per-app step this tool intentionally does not automate)."
echo -e "${C_SUCCESS}------------------------------------------------${C_RESET}"
echo ""
echo -e "${C_WARN}⚠️  SHOWN ONCE - Cloudflare never returns this secret again. Copy it now.${C_RESET}"
echo -e "${C_INFO}=============================================================================${C_RESET}"
echo -e "${C_INFO}📋 COPY-PASTE SNIPPET FOR YOUR RAILS APP CREDENTIALS (upload bucket only)${C_RESET}"
echo -e "${C_INFO}=============================================================================${C_RESET}"
echo -e "${C_WARN}# 1. Add these to your Rails encrypted credentials (e.g. EDITOR=vim bin/rails${C_RESET}"
echo -e "${C_WARN}#    credentials:edit --environment=$ENVIRONMENT):${C_RESET}"
cat <<SNIPPET
r2:
  public_bucket: "$UPL_BUCKET"
  access_key_id: "$UPL_ACCESS_KEY_ID"
  secret_access_key: "$UPL_SECRET_ACCESS_KEY"
  endpoint: "$CF_R2_S3_CLIENT_URL"
SNIPPET
echo -e "${C_WARN}#${C_RESET}"
echo -e "${C_WARN}# 2. Reference them inside config/storage.yml using your standard patterns.${C_RESET}"
echo -e "${C_WARN}# This credential can ONLY reach '$UPL_BUCKET' - it has no access to the${C_RESET}"
echo -e "${C_WARN}# backup bucket, even if this app is compromised.${C_RESET}"
echo -e "${C_INFO}=============================================================================${C_RESET}"
echo ""
