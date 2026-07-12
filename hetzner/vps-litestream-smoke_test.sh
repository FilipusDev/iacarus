#!/bin/bash

set -e

source ../config.sh
source ../utils.sh

# 1. Check configuration variables availability
echo -e "\n${C_INFO}🔍 Checking Pre-requisites...${C_RESET}"
if [[ -z "$AWS_ACCESS_KEY_ID" || -z "$AWS_SECRET_ACCESS_KEY" || -z "$CF_R2_S3_CLIENT_URL" ]]; then
    echo -e "${C_ERROR}❌ Error: Missing configuration variables.${C_RESET}"
    exit 1
fi

# 2. Get Server Details (Sets $SELECTED_NAME)
select_server_interactive

# 3. Pre-Flight Connection Check
if ! check_ssh_access "$SELECTED_NAME"; then
    exit 1
fi

# 4. Define Disposable Test Resources
LABEL="smoke-test"
VOLUME="smoke_litestream_data"
DB_PATH="/var/lib/docker/volumes/${VOLUME}/_data/smoke.sqlite3"
BUCKET_NAME="smoke-test-litestream-$(date +%s)"

echo -e "\n${C_INFO}🌫️  Starting Litestream Smoke Test on${C_RESET}${C_HIGH} '$SELECTED_NAME'${C_RESET}..."
echo "----------------------------------------"

# 5. Cleanup (always runs on exit, success or failure)
function cleanup() {
    set +e
    echo ""
    echo -e "${C_INFO}🧹 Cleaning up...${C_RESET}"

    if ssh -q "$SELECTED_NAME" "sudo grep -qF -- '  # $LABEL' /etc/litestream.yml" 2>/dev/null; then
        litestream_remove_db "$SELECTED_NAME" "$LABEL" > /dev/null 2>&1
    fi

    ssh -q "$SELECTED_NAME" "docker volume rm -f $VOLUME" > /dev/null 2>&1

    aws s3 rb "s3://$BUCKET_NAME" --force --endpoint-url "$CF_R2_S3_CLIENT_URL" > /dev/null 2>&1

    echo -e "${C_SUCCESS}✅ Cleaned up.${C_RESET}"
}
trap cleanup EXIT

# 6. Create a Throwaway Bucket
echo -n "1. Creating throwaway bucket ($BUCKET_NAME)... "
aws s3api create-bucket --bucket "$BUCKET_NAME" --endpoint-url "$CF_R2_S3_CLIENT_URL" > /dev/null
echo -e "${C_SUCCESS}OK${C_RESET}"

# 7. Create a Real SQLite DB on the Box
echo -n "2. Creating disposable SQLite DB on $SELECTED_NAME... "
ssh -q "$SELECTED_NAME" "docker volume create $VOLUME > /dev/null && docker run --rm -v $VOLUME:/data alpine sh -c 'apk add --no-cache sqlite > /dev/null 2>&1 && sqlite3 /data/smoke.sqlite3 \"CREATE TABLE smoke (id INTEGER PRIMARY KEY, ts TEXT); INSERT INTO smoke (ts) VALUES (datetime());\"'" > /dev/null
echo -e "${C_SUCCESS}OK${C_RESET}"

# 8. Register the DB for Replication
echo -n "3. Registering DB for replication... "
if litestream_register_db "$SELECTED_NAME" "$LABEL" "$DB_PATH" "$BUCKET_NAME" "$CF_R2_S3_CLIENT_URL" "$CF_R2_S3_CLIENT_ACCESS_KEY_ID" "$CF_R2_S3_CLIENT_SECRET_ACCESS_KEY" > /dev/null; then
    echo -e "${C_SUCCESS}OK${C_RESET}"
else
    echo -e "${C_ERROR}FAILED (litestream did not (re)start)${C_RESET}"
    exit 1
fi

# 9. Poll R2 for Replicated Objects
echo -n "4. Waiting for replication to land in R2 "
REPLICATED=0
for i in {1..15}; do
    if aws s3 ls "s3://$BUCKET_NAME/" --recursive --endpoint-url "$CF_R2_S3_CLIENT_URL" 2>/dev/null | grep -q "generations/"; then
        REPLICATED=1
        break
    fi
    echo -n "."
    sleep 2
done

if [ "$REPLICATED" -eq 1 ]; then
    echo -e " ${C_SUCCESS}OK${C_RESET}"
else
    echo -e " ${C_ERROR}FAILED (no replicated objects found in R2 after 30s)${C_RESET}"
    exit 1
fi

echo ""
echo -e "${C_SUCCESS}🎉 SMOKE TEST PASSED! Litestream is replicating to R2 end-to-end.${C_RESET}"
