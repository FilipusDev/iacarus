#!/bin/bash

# --- COLOR DEFINITIONS ---

C_ERROR='\e[1;31m'      # Bold Red (Critical)
C_SUCCESS='\e[1;32m'    # Bold Green (Success)
C_WARN='\e[1;38;5;226m' # Bold Yellow
C_INFO='\e[38;5;39m'    # Blue
C_HIGH='\e[38;5;171m'   # Turquoise
C_RESET='\e[0m'

# --- SOURCE ENV FILE ---

# 1. Determine the Project Root (Where .env lives)
if [ -f ".env" ]; then
  ENV_FILE=".env"
elif [ -f "../.env" ]; then
  ENV_FILE="../.env"
else
  echo -e "${C_ERROR}❌ Error: Could not find .env file.${C_RESET}"
  exit 1
fi

# 2. Source it
source "$ENV_FILE"

# --- SSH KEY CONFIG ---

SSH_PUBLIC_KEY_PATH=${SSH_PUBLIC_KEY_PATH}
SSH_PRIVATE_KEY_PATH=${SSH_PRIVATE_KEY_PATH}

# --- HETZNER VPS CONFIG ---

VPS_BASE_NAME=${VPS_BASE_NAME}
VPS_TYPE=${VPS_TYPE}
VPS_LOCATION=${VPS_LOCATION}
VPS_IMAGE=${VPS_IMAGE}
ENVIRONMENT=${ENVIRONMENT}
VPS_ADMIN_USER=${VPS_ADMIN_USER}

# --- CLOUDFLARE ZERO TRUST TUNNEL CONFIG ---

CF_TUNNEL_SMOKE_TEST_TOKEN=${CF_TUNNEL_SMOKE_TEST_TOKEN}

# --- CLOUDFLARE R2 BUCKET CONFIG ---

CF_R2_S3_CLIENT_URL=${CF_R2_S3_CLIENT_URL}
CF_R2_BUCKET_BASE_NAME="cf-bucket-"

# --- GLOBAL AWS CLI CONFIG ---
export AWS_ACCESS_KEY_ID="$CF_R2_S3_CLIENT_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$CF_R2_S3_CLIENT_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="auto"
