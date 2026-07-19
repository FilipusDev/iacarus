#!/bin/bash

# --- COLOR DEFINITIONS ---

C_ERROR='\e[1;31m'      # Bold Red (Critical)
C_SUCCESS='\e[1;32m'    # Bold Green (Success)
C_WARN='\e[1;38;5;226m' # Bold Yellow
C_INFO='\e[38;5;39m'    # Blue
C_HIGH='\e[38;5;171m'   # Turquoise
C_RESET='\e[0m'

# --- TOOLKIT VERSIONS ---

LITESTREAM_VERSION="v0.3.13"

# --- SOURCE ENV FILE ---

# 1. Determine the Project Root (Where .env lives)
if [ -f ".env" ]; then
  ENV_FILE=".env"
  PROJECT_ROOT="."
elif [ -f "../.env" ]; then
  ENV_FILE="../.env"
  PROJECT_ROOT=".."
else
  echo -e "${C_ERROR}❌ Error: Could not find .env file.${C_RESET}"
  exit 1
fi

# 2. Source it
source "$ENV_FILE"

# --- MON (OBSERVABILITY) CONFIG ---

# The app registry the stateless viewer reads (SPRINT B0). Operator state, NOT
# source: it carries client base URLs and is gitignored - `mon/registry.example.json`
# is the committed shape reference. Resolved off PROJECT_ROOT so the path is
# identical whether a script runs from the repo root or a domain dir.
# Overridable so a mon box can point at a registry kept outside the repo (and so
# it can be exercised against a fixture) without editing anything.
MON_REGISTRY="${MON_REGISTRY:-${PROJECT_ROOT}/mon/registry.json}"

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

# --- CLOUDFLARE API (TOKEN FACTORY) CONFIG ---

# The single, canonical Cloudflare Account ID. Shared by the token factory AND
# the R2 S3 endpoint below.
CF_ACCOUNT_ID=${CF_ACCOUNT_ID}

# High-level bearer token used to MINT/REVOKE per-app scoped R2 tokens.
# Requires the account permissions: "API Tokens:Edit" + "Workers R2 Storage:Edit".
CF_API_BEARER_TOKEN=${CF_API_BEARER_TOKEN}

# Cloudflare API base + the R2 bucket-item permission groups attached to every
# minted token. Both READ and WRITE are granted so Litestream can restore (read
# + list) as well as replicate (write). IDs are stable per account and were
# resolved from GET /accounts/<id>/tokens/permission_groups.
CF_API_BASE="https://api.cloudflare.com/client/v4"
CF_R2_PG_BUCKET_ITEM_WRITE="2efd5506f9c8494dacb1fa10a3e7d5b6"
CF_R2_PG_BUCKET_ITEM_READ="6a018a9f2fc74eb6b293b0c548f38b39"
CF_R2_JURISDICTION="default"

# --- CLOUDFLARE ZERO TRUST TUNNEL CONFIG ---

CF_TUNNEL_SMOKE_TEST_TOKEN=${CF_TUNNEL_SMOKE_TEST_TOKEN}

# --- CLOUDFLARE R2 BUCKET CONFIG ---

CF_R2_S3_CLIENT_URL=${CF_R2_S3_CLIENT_URL}
CF_R2_BUCKET_BASE_NAME="cf-bucket-"

# --- GLOBAL AWS CLI CONFIG ---
export AWS_ACCESS_KEY_ID="$CF_R2_S3_CLIENT_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$CF_R2_S3_CLIENT_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="auto"
