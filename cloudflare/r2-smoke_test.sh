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

# Generate a random bucket name
BUCKET_NAME="smoke-test-$(date +%s)"
TEST_FILE="smoke.txt"

echo -e "${C_INFO}🌫️  Starting R2 Smoke Test...${C_RESET}"
echo "   Endpoint: $CF_R2_S3_CLIENT_URL"
echo "   Bucket:   $BUCKET_NAME"

# 2. Create Bucket
echo -n "   Creating bucket... "
aws s3api create-bucket --bucket "$BUCKET_NAME" --endpoint-url "$CF_R2_S3_CLIENT_URL" > /dev/null
echo -e "${C_SUCCESS}OK${C_RESET}"

# 3. Create Dummy File
echo "Hello from Arch Linux" > "$TEST_FILE"

# 4. Upload File
echo -n "   Uploading object... "
aws s3 cp "$TEST_FILE" "s3://$BUCKET_NAME/remote-smoke.txt" --endpoint-url "$CF_R2_S3_CLIENT_URL" > /dev/null
echo -e "${C_SUCCESS}OK${C_RESET}"

# 5. List Object
echo -n "   Verifying object exists... "
if aws s3 ls "s3://$BUCKET_NAME" --endpoint-url "$CF_R2_S3_CLIENT_URL" | grep -q "remote-smoke.txt"; then
    echo -e "${C_SUCCESS}OK${C_RESET}"
else
    echo -e "${C_ERROR}FAILED (File not found)${C_RESET}"
    # Cleanup before exiting
    aws s3 rb "s3://$BUCKET_NAME" --force --endpoint-url "$CF_R2_S3_CLIENT_URL" > /dev/null
    exit 1
fi

# 6. Download Object
echo -n "   Downloading object... "
aws s3 cp "s3://$BUCKET_NAME/remote-smoke.txt" "downloaded-smoke.txt" --endpoint-url "$CF_R2_S3_CLIENT_URL" > /dev/null
echo -e "${C_SUCCESS}OK${C_RESET}"

# 7. Compare Content
echo -n "   Comparing content... "
if diff "$TEST_FILE" "downloaded-smoke.txt"; then
    echo -e "${C_SUCCESS}MATCHED (Integrity Confirmed)${C_RESET}"
else
    echo -e "${C_ERROR}MISMATCH (Data Corruption?)${C_RESET}"
    exit 1
fi

# 8. Cleanup
echo -n "   Cleaning up... "
# Use --force to delete bucket AND objects in one go
aws s3 rb "s3://$BUCKET_NAME" --force --endpoint-url "$CF_R2_S3_CLIENT_URL" > /dev/null
rm "$TEST_FILE" "downloaded-smoke.txt"
echo -e "${C_SUCCESS}OK${C_RESET}"

echo ""
echo -e "${C_SUCCESS}🎉 SMOKE TEST PASSED! Your R2 keys work perfectly.${C_RESET}"
