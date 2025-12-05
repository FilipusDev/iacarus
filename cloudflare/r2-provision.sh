#!/bin/bash

set -e

source ../config.sh
source ../utils.sh

# 1. Check configuration variables availability
echo -e "\n${C_INFO}🔍 Checking Pre-requisites...${C_RESET}"
if [[ -z "$AWS_ACCESS_KEY_ID" || -z "$AWS_SECRET_ACCESS_KEY" || -z "$AWS_DEFAULT_REGION" || -z "$CF_R2_S3_CLIENT_URL" || -z "$CF_R2_BUCKET_BASE_NAME" ]]; then
    echo -e "${C_ERROR}❌ Error: Missing configuration variables.${C_RESET}"
    exit 1
fi

# 2. Define a bucket name
echo -e "${C_INFO}🪣 Provisioning a new Cloudflare R2 BUCKET...${C_RESET}"
echo -n ">  Type the BUCKET name to complement (${CF_R2_BUCKET_BASE_NAME}): "
read BUCKET_COMPLEMENT_NAME

if [ -z "$BUCKET_COMPLEMENT_NAME" ]; then
    echo -e "${C_ERROR}❌ The BUCKET needs a name. Aborted.${C_RESET}"
    exit 1
fi

BUCKET_FULL_NAME=${CF_R2_BUCKET_BASE_NAME}${BUCKET_COMPLEMENT_NAME}

# 3. Check bucket name uniqueness and Create if not exists
echo -e "${C_INFO}🔍 Checking if ${C_RESET}${C_HIGH}$BUCKET_FULL_NAME${C_RESET}${C_INFO} exists...${C_RESET}"

if aws s3api head-bucket --bucket "$BUCKET_FULL_NAME" --endpoint-url "$CF_R2_S3_CLIENT_URL" > /dev/null 2>&1; then
    echo -e "${C_WARN}⚠️  Bucket '$BUCKET_FULL_NAME' already exists. Skipping creation.${C_RESET}"
else
    echo -e "${C_INFO}🚰 Creating bucket '$BUCKET_FULL_NAME'...${C_RESET}"
    aws s3api create-bucket --bucket "$BUCKET_FULL_NAME" --endpoint-url "$CF_R2_S3_CLIENT_URL" > /dev/null
    echo -e "${C_SUCCESS}✅ Bucket created successfully!${C_RESET}"
fi

# 4. List all buckets after creation
echo ""
echo -e "${C_INFO}📋 Current Buckets:${C_RESET}"
aws s3api list-buckets --endpoint-url "$CF_R2_S3_CLIENT_URL" --query "Buckets[].Name" --output table
