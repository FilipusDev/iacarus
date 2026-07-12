#!/bin/bash

set -e

source ../config.sh
source ../utils.sh

# 1. Check configuration variables availability
echo -e "\n${C_INFO}🔍 Checking Pre-requisites...${C_RESET}"
if [[ -z "$CF_R2_S3_CLIENT_URL" || -z "$CF_R2_S3_CLIENT_ACCESS_KEY_ID" || -z "$CF_R2_S3_CLIENT_SECRET_ACCESS_KEY" ]]; then
    echo -e "${C_ERROR}❌ Error: Missing configuration variables.${C_RESET}"
    exit 1
fi

# 2. Get Server Details (Sets $SELECTED_NAME)
select_server_interactive

# 3. Pre-Flight Connection Check
if ! check_ssh_access "$SELECTED_NAME"; then
    exit 1
fi

# 4. Collect App Details
echo -e "\n${C_INFO}🗄️  Registering a new SQLite DB for Litestream replication on ${C_RESET}${C_HIGH}$SELECTED_NAME${C_RESET}${C_INFO}...${C_RESET}"

echo -n ">  App label (for your reference only, e.g. 'blog'): "
read APP_LABEL

if [ -z "$APP_LABEL" ]; then
    echo -e "${C_ERROR}❌ An app label is required. Aborted.${C_RESET}"
    exit 1
fi

echo -n ">  Full path to the SQLite DB inside its Docker volume (e.g. /var/lib/docker/volumes/blog_data/_data/production.sqlite3): "
read DB_PATH

if [ -z "$DB_PATH" ]; then
    echo -e "${C_ERROR}❌ A DB path is required. Aborted.${C_RESET}"
    exit 1
fi

echo -n ">  Target R2 bucket name (must already exist - see 'cd cloudflare && make bucket-new'): "
read BUCKET_NAME

if [ -z "$BUCKET_NAME" ]; then
    echo -e "${C_ERROR}❌ A bucket name is required. Aborted.${C_RESET}"
    exit 1
fi

# 5. Verify the Target Bucket Already Exists
echo -e "${C_INFO}🔍 Verifying bucket '$BUCKET_NAME' exists...${C_RESET}"
if ! aws s3api head-bucket --bucket "$BUCKET_NAME" --endpoint-url "$CF_R2_S3_CLIENT_URL" > /dev/null 2>&1; then
    echo -e "${C_ERROR}❌ Bucket '$BUCKET_NAME' not found. Create it first: cd ../cloudflare && make bucket-new${C_RESET}"
    exit 1
fi

# 6. Guard Against Duplicate Registration
echo -e "${C_INFO}🔍 Checking for an existing entry on $SELECTED_NAME...${C_RESET}"
if ssh -q "$SELECTED_NAME" "sudo grep -qF -- 'path: $DB_PATH' /etc/litestream.yml"; then
    echo -e "${C_ERROR}❌ '$DB_PATH' is already registered on $SELECTED_NAME. Aborted.${C_RESET}"
    exit 1
fi

# 7. Append the DB Entry & Restart Litestream to Pick It Up
echo -e "${C_INFO}📝 Appending '$APP_LABEL' ($DB_PATH -> $BUCKET_NAME) to /etc/litestream.yml...${C_RESET}"
echo -e "${C_INFO}🔄 Restarting litestream...${C_RESET}"

if litestream_register_db "$SELECTED_NAME" "$APP_LABEL" "$DB_PATH" "$BUCKET_NAME" "$CF_R2_S3_CLIENT_URL" "$CF_R2_S3_CLIENT_ACCESS_KEY_ID" "$CF_R2_S3_CLIENT_SECRET_ACCESS_KEY"; then
    echo -e "${C_SUCCESS}✅ '$APP_LABEL' registered and replicating to '$BUCKET_NAME'.${C_RESET}"
else
    echo -e "${C_ERROR}❌ litestream failed to (re)start. Check 'journalctl -u litestream' on $SELECTED_NAME.${C_RESET}"
    exit 1
fi
