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
#
# Resolved from this file's own location, never from the caller's cwd. config.sh is sourced three
# ways — from the repo root (`source config.sh`), from a domain dir (`source ../config.sh`), and by
# absolute path (fleet-doctor) — and a cwd-relative probe finds .env for the first two but misses it
# for any caller invoked from somewhere else. That miss is worse than it looks: `exit` inside a
# sourced file terminates the CALLER, so the failure presents as the caller dying with no output at
# all, no matter what guard it wrapped the `source` in.
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo -e "${C_ERROR}❌ Error: Could not find .env file (looked in ${PROJECT_ROOT}).${C_RESET}" >&2
  echo -e "   Run 'make setup' to create one from .env.example." >&2
  exit 1
fi

# 2. Source it, resolving 1Password references when present.
#
# Secrets in .env are `op://` references, not values (see .env.example). `op inject` swaps each
# reference for its value in ONE call — one desktop-app authorization, never six — and passes every
# other line through untouched, including `${...}` shell interpolations, which bash then expands at
# source time exactly as before (that is what keeps CF_R2_S3_CLIENT_URL reusing CF_ACCOUNT_ID).
# Values exist only in this process's environment; nothing is written to disk.
#
# A .env with no references (a mon box's MON_*-only file, or a fresh literal-filled copy) skips op
# entirely, so boxes without 1Password keep working unchanged.
if grep -qE '^[A-Za-z_][A-Za-z0-9_]*=op://' "$ENV_FILE"; then
  if ! command -v op > /dev/null 2>&1; then
    echo -e "${C_ERROR}❌ Error: $ENV_FILE holds op:// references but the 1Password CLI (op) is not installed.${C_RESET}"
    echo -e "   Install it, or replace the references with literal values on a machine that cannot run op."
    exit 1
  fi
  # Capture BEFORE sourcing, because `source <(op inject …)` cannot fail: process substitution
  # reports the exit status of `source` reading an empty stream, not of `op inject`. A locked or
  # dismissed vault therefore looked like success and left every value unset — the guard below has
  # never once fired. Downstream that is worse than a hard stop: scripts carry on with empty tokens.
  #
  # The resolved text sits in a shell variable for exactly two lines and is unset immediately. That
  # keeps the values in this process's memory, the same boundary as before — nothing reaches disk.
  ENV_RESOLVED="$(op inject -i "$ENV_FILE")" || {
    echo -e "${C_ERROR}❌ Error: op inject could not resolve $ENV_FILE (is 1Password unlocked?).${C_RESET}" >&2
    exit 1
  }
  source <(printf '%s\n' "$ENV_RESOLVED")
  unset ENV_RESOLVED
else
  source "$ENV_FILE"
fi

# --- MON (OBSERVABILITY) CONFIG ---

# The app registry the stateless viewer reads (SPRINT B0). Operator state, NOT
# source: it carries client base URLs and is gitignored - `mon/registry.example.json`
# is the committed shape reference. Resolved off PROJECT_ROOT so the path is
# identical whether a script runs from the repo root or a domain dir.
# Overridable so a mon box can point at a registry kept outside the repo (and so
# it can be exercised against a fixture) without editing anything.
MON_REGISTRY="${MON_REGISTRY:-${PROJECT_ROOT}/mon/registry.json}"

# App board (B4) thresholds, judged on TOTAL round-trip in milliseconds: under
# WARN is green, between WARN and CRIT is yellow, at/over CRIT (or any non-200)
# is red.
#
# These measure the trip from WHEREVER THE VIEWER RUNS to the app - so they are
# a property of the observer, not of the app. Measured baseline from Brazil to a
# Helsinki box behind a Cloudflare tunnel: ~250ms steady, with reconnect
# outliers near 580ms, while the app itself answers /up in 3-6ms on the box. The
# defaults below sit above that noise. A mon box in Europe would see ~10ms and
# should run far tighter numbers - override in .env rather than assuming these
# travel.
MON_LATENCY_WARN_MS="${MON_LATENCY_WARN_MS:-1200}"
MON_LATENCY_CRIT_MS="${MON_LATENCY_CRIT_MS:-3000}"

# Seconds between redraws of the live board, and the per-request timeout.
MON_REFRESH_SECONDS="${MON_REFRESH_SECONDS:-10}"
MON_HTTP_TIMEOUT="${MON_HTTP_TIMEOUT:-15}"

# Warn when a TLS certificate expires within this many days.
MON_TLS_WARN_DAYS="${MON_TLS_WARN_DAYS:-21}"

# Hardware board (B2). The glances server on each box listens on LOOPBACK only,
# so the viewer reaches every box through its own SSH tunnel - never an open
# port. MON_GLANCES_PORT is the REMOTE port (the glances default, identical on
# every box, since nothing else ever sees it). The viewer then allocates one
# distinct LOCAL port per box starting at MON_GLANCES_LOCAL_PORT_BASE, skipping
# anything already in use, and points glances' browser mode at those.
MON_GLANCES_PORT="${MON_GLANCES_PORT:-61209}"
MON_GLANCES_LOCAL_PORT_BASE="${MON_GLANCES_LOCAL_PORT_BASE:-61209}"

# How long to wait for each SSH tunnel to start accepting connections.
MON_TUNNEL_TIMEOUT="${MON_TUNNEL_TIMEOUT:-15}"

# Name prefix for MON boxes (B3), kept distinct from VPS_BASE_NAME so the two
# profiles number independently and a mon box is identifiable at a glance in
# 'hcloud server list'. Where the viewer lives on that box - the repo is copied
# there by 'make vps-mon-setup', which also generates the box's own ssh key.
MON_VPS_BASE_NAME="${MON_VPS_BASE_NAME:-hetzner-mon-}"
MON_REMOTE_PATH="${MON_REMOTE_PATH:-/opt/iacarus}"

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
