#!/bin/bash

set -e

source ../config.sh
source ../utils.sh

# 1. Check configuration variables availability
echo -e "\n${C_INFO}🔍 Checking Pre-requisites...${C_RESET}"
if [[ -z "$AWS_ACCESS_KEY_ID" || -z "$CF_R2_S3_CLIENT_URL" ]]; then
    echo -e "${C_ERROR}❌ Error: Missing configuration variables.${C_RESET}"
    exit 1
fi

echo -e "${C_INFO}🔍 Fetching buckets from R2...${C_RESET}"

# 2. Check for existence (Get raw names)
RAW_LIST=$(aws s3api list-buckets --endpoint-url "$CF_R2_S3_CLIENT_URL" --query "Buckets[].Name" --output text 2>/dev/null)

# 3. Conditional Output
if [[ -z "$RAW_LIST" || "$RAW_LIST" == "None" ]]; then
    echo -e "${C_WARN}🤷 No buckets found.${C_RESET}"
else
    aws s3api list-buckets \
      --endpoint-url "$CF_R2_S3_CLIENT_URL" \
      --query "Buckets[].{Name:Name, Created:CreationDate}" \
      --output table
fi
