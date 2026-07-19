#!/bin/bash

# --- GLOBAL ERROR HANDLER ---

# 1. Define the function that runs when things explode
function handle_error() {
    local exit_code=$?
    local last_command="${BASH_COMMAND}"

    echo ""
    echo -e "${C_ERROR}💥 Script aborted!\n${C_RESET}"
    echo -e "${C_WARN}Command failed: ${C_INFO}$last_command${C_RESET}"
    echo -e "${C_WARN}Exit code:      ${C_INFO}$exit_code${C_RESET}"

    # Exit Code 127 = "Command Not Found" (Missing Dependency)
    if [ $exit_code -eq 127 ]; then
        echo -e "\n${C_WARN}🔍 Diagnosis: A required tool seems to be missing.${C_RESET}"
    fi

    echo -e "\n${C_INFO}👉 RECOMMENDATION:${C_RESET}"
    echo -e "   Run ${C_SUCCESS}make setup${C_RESET} from the project root."
    echo ""
}

# 2. Arm the Trap
# "If any command fails (ERR), run 'handle_error'"
trap 'handle_error' ERR

# --- FUNCTIONS HETZNER ---

# Function: Clean SSH entries for a specific host/IP/Port
function clean_known_hosts() {
    local HOST=$1
    local IP=$2
    local PORT=$3

    # 1. Remove by Hostname
    ssh-keygen -R "$HOST" > /dev/null 2>&1 || true

    # 2. Remove by IP (Standard)
    ssh-keygen -R "$IP" > /dev/null 2>&1 || true

    # 3. Remove by [IP]:PORT (Critical for custom ports)
    if [ -n "$PORT" ]; then
        ssh-keygen -R "[$IP]:$PORT" > /dev/null 2>&1 || true
        ssh-keygen -R "[$HOST]:$PORT" > /dev/null 2>&1 || true
    fi
}

# Function: Fail-Fast SSH Check
function check_ssh_access() {
    local HOST_ALIAS=$1

    echo -en "\n🔌 Testing connection to $HOST_ALIAS... "

    # -o BatchMode=yes: Fails if key auth fails (won't ask for password)
    # -o ConnectTimeout=5: Fails if network/firewall is blocking
    if ssh -q -o BatchMode=yes -o ConnectTimeout=5 "$HOST_ALIAS" exit; then
        echo -e "${C_SUCCESS}OK${C_RESET}"
        return 0
    else
        echo -e "${C_ERROR}FAILED${C_RESET}"
        echo -e "${C_WARN}   Could not connect. Check VPN, Firewall, or SSH Key.${C_RESET}"
        return 1
    fi
}

# Function: Interactive Server Selection
function select_server_interactive() {
    echo -e "\n${C_INFO}🔍 Fetching server list from Hetzner...${C_RESET}"

    mapfile -t SERVERS < <(hcloud server list -o noheader -o columns=id,name,ipv4,status | awk 'NF {print $1 ":" $2 ":" $3 ":" $4}')

    if [ ${#SERVERS[@]} -eq 0 ]; then
        echo -e "${C_WARN}🤷 No servers found.${C_RESET}"
        exit 0
    fi

    echo "Select a server:"
    PS3="Enter number (or 'q' to quit): "

    select ITEM in "${SERVERS[@]}"; do
        [[ "$REPLY" == "q" ]] && echo "Aborted." && exit 0

        if [ -n "$ITEM" ]; then
            IFS=':' read -r SELECTED_ID SELECTED_NAME SELECTED_IP SELECTED_STATUS <<< "$ITEM"
            break
        else
            echo "Invalid selection."
        fi
    done
}

# Function: Append a DB entry to a remote host's /etc/litestream.yml and
# restart the daemon so it picks it up. Returns 0 if litestream ends up
# active, 1 otherwise.
function litestream_register_db() {
    local HOST=$1
    local LABEL=$2
    local DB_PATH=$3
    local BUCKET_NAME=$4
    local ENDPOINT=$5
    local ACCESS_KEY=$6
    local SECRET_KEY=$7

    ssh -q "$HOST" "sudo tee -a /etc/litestream.yml > /dev/null" <<EOF
  # $LABEL
  - path: $DB_PATH
    replicas:
      - type: s3
        bucket: $BUCKET_NAME
        region: auto
        endpoint: $ENDPOINT
        access-key-id: $ACCESS_KEY
        secret-access-key: $SECRET_KEY
EOF

    ssh -q "$HOST" "sudo systemctl restart litestream"
    ssh -q "$HOST" "systemctl is-active --quiet litestream"
}

# Function: Remove a labeled DB entry from a remote host's
# /etc/litestream.yml and restart the daemon. Entries are matched by their
# "  # <label>" comment line through to the next entry's comment (or EOF).
# The filtered content is copied (not moved) onto the existing file so its
# 0600 root:root permissions are preserved rather than replaced. Returns 0
# if litestream ends up active, 1 otherwise.
function litestream_remove_db() {
    local HOST=$1
    local LABEL=$2

    ssh -q "$HOST" "sudo awk -v label='  # $LABEL' '\$0==label{skip=1;next} skip&&/^  # /{skip=0} !skip' /etc/litestream.yml > /tmp/litestream.yml.tmp && sudo cp /tmp/litestream.yml.tmp /etc/litestream.yml && rm -f /tmp/litestream.yml.tmp"

    ssh -q "$HOST" "sudo systemctl restart litestream"
    ssh -q "$HOST" "systemctl is-active --quiet litestream"
}

# --- FUNCTIONS MON (APP REGISTRY) ---

# Function: Upsert an app into $MON_REGISTRY (SPRINT B0). Keyed on <APP_SLUG>,
# which is fleet-unique (it is what the R2 buckets and scoped tokens are named
# after) - unlike <LABEL>, whose uniqueness is only ever enforced per-box.
# Idempotent by construction: any row with the same slug is filtered out before
# the new one is appended, so re-running an add updates in place instead of
# duplicating. Written via a sibling temp file + atomic rename, because jq
# cannot read and write the same file in one pass (it would truncate it).
# Creates the file (and mon/) on first use. Returns 0 on success.
function mon_registry_add() {
    local APP_SLUG=$1
    local BOX=$2
    local LABEL=$3
    local BASE_URL=$4
    local HEALTH_PATH=$5
    local NAME=$6

    mkdir -p "$(dirname "$MON_REGISTRY")"
    [ -f "$MON_REGISTRY" ] || echo '[]' > "$MON_REGISTRY"

    local TMP
    TMP=$(mktemp "${MON_REGISTRY}.XXXXXX")

    jq --arg slug "$APP_SLUG" \
       --arg box "$BOX" \
       --arg label "$LABEL" \
       --arg base_url "$BASE_URL" \
       --arg health_path "$HEALTH_PATH" \
       --arg name "$NAME" \
       'map(select(.app_slug != $slug))
        + [{
            app_slug:    $slug,
            box:         $box,
            label:       $label,
            base_url:    $base_url,
            health_path: $health_path,
            name:        $name
          }]
        | sort_by(.app_slug)' "$MON_REGISTRY" > "$TMP" \
        && mv "$TMP" "$MON_REGISTRY"
}

# Function: Drop an app from $MON_REGISTRY, resolving it by <BOX> + <LABEL> -
# the only pair vps-rails-app-remove.sh reliably holds. It derives APP_SLUG from
# a litestream bucket read that is explicitly allowed to fail non-fatally, so
# depending on that read here would orphan the registry row in exactly the
# degraded case where cleanup matters most. The lookup is therefore purely
# local (jq, no SSH). Prints the slug it removed.
# Returns 1 on a miss (unknown app, or one that predates the registry) so the
# caller can warn and continue rather than abort.
# CALL IT IN A CONDITION - `if SLUG=$(mon_registry_remove "$BOX" "$LABEL"); then`.
# A bare call trips the global ERR trap on the miss path and prints the "Script
# aborted!" panic block for what is a perfectly normal outcome.
function mon_registry_remove() {
    local BOX=$1
    local LABEL=$2

    [ -f "$MON_REGISTRY" ] || return 1

    local SLUG
    SLUG=$(jq -r --arg box "$BOX" --arg label "$LABEL" \
        'map(select(.box == $box and .label == $label)) | .[0].app_slug // empty' \
        "$MON_REGISTRY")

    [ -z "$SLUG" ] && return 1

    local TMP
    TMP=$(mktemp "${MON_REGISTRY}.XXXXXX")

    jq --arg slug "$SLUG" 'map(select(.app_slug != $slug))' "$MON_REGISTRY" > "$TMP" \
        && mv "$TMP" "$MON_REGISTRY" \
        && echo "$SLUG"
}

# Function: Report where the viewer is running (SPRINT B1). The viewer is
# stateless and portable - the SAME code runs from a laptop or a dedicated mon
# box - so this is never a code fork, only a runtime capability question:
#   operator = hcloud answers, so the Hetzner fleet can be enumerated live
#              (provisioning creds present; typically the laptop)
#   viewer   = no usable hcloud, so the registry + ssh config are all we have
#              (a credential-less mon box, or a laptop with creds unloaded)
# Both contexts render apps identically - B4 only needs curl + the registry.
# The difference is whether hardware targets can be discovered or must be read
# from what the registry already records.
function mon_context() {
    if command -v hcloud > /dev/null 2>&1 && hcloud server list -o noheader > /dev/null 2>&1; then
        echo "operator"
    else
        echo "viewer"
    fi
}

# Function: Emit the registry as one compact JSON object per line - the read
# path B1/B4 iterate over. Absent/empty registry emits nothing (exit 0), so a
# fresh clone or a credential-less laptop degrades to "no apps", never an error.
function mon_registry_list() {
    [ -f "$MON_REGISTRY" ] || return 0

    jq -c '.[]' "$MON_REGISTRY"
}

# Function: Read the access-key-id (which, for tokens minted by this tool, IS
# the Cloudflare token id) out of a labeled entry in a remote host's
# /etc/litestream.yml. Matches the "  # <label>" block through to the next
# entry's comment (or EOF) and prints the first access-key-id found. Prints
# nothing if the label or field is absent.
function litestream_get_access_key() {
    local HOST=$1
    local LABEL=$2

    ssh -q "$HOST" "sudo awk -v label='  # $LABEL' '\$0==label{f=1;next} f&&/^  # /{f=0} f&&/access-key-id:/{print \$2; exit}' /etc/litestream.yml"
}

# Function: Read the bucket name out of a labeled entry in a remote host's
# /etc/litestream.yml. Same matching rules as litestream_get_access_key.
# Used to derive the app slug (and from it, the sibling upload bucket/token
# name) without needing any separate local registry file.
function litestream_get_bucket() {
    local HOST=$1
    local LABEL=$2

    ssh -q "$HOST" "sudo awk -v label='  # $LABEL' '\$0==label{f=1;next} f&&/^  # /{f=0} f&&/bucket:/{print \$2; exit}' /etc/litestream.yml"
}

# --- FUNCTIONS CLOUDFLARE ---

# Function: Mint an account-owned R2 API token scoped to EXACTLY ONE bucket
# and derive its S3 credential pair. Carries both the R2 bucket-item READ and
# WRITE permission groups (so the holder can restore/serve as well as write).
#
#   cloudflare_create_scoped_token <TOKEN_NAME> <BUCKET_NAME>
#
# Each app gets TWO of these (one per bucket) rather than one token shared
# across both buckets - this keeps them genuinely isolated: a credential
# handed to the app (upload bucket) can never touch the backup bucket, and
# vice-versa.
#
# On success (return 0) it sets three globals for the caller to consume:
#   CF_SCOPED_TOKEN_ID          - the token id (also the S3 Access Key ID)
#   CF_SCOPED_ACCESS_KEY_ID     - alias of the above, for readability
#   CF_SCOPED_SECRET_ACCESS_KEY - SHA-256 hex digest of the raw token value
# The raw token value is never written to disk and never echoed. Returns 1 on
# any Cloudflare API failure (with the API's error messages printed to stderr).
function cloudflare_create_scoped_token() {
    local TOKEN_NAME=$1
    local BUCKET_NAME=$2

    if [[ -z "$CF_API_BEARER_TOKEN" || -z "$CF_ACCOUNT_ID" ]]; then
        echo -e "${C_ERROR}❌ Missing CF_API_BEARER_TOKEN or CF_ACCOUNT_ID.${C_RESET}" >&2
        return 1
    fi

    # R2 bucket resource identifier: <account_id>_<jurisdiction>_<bucket_name>
    local RESOURCE="com.cloudflare.edge.r2.bucket.${CF_ACCOUNT_ID}_${CF_R2_JURISDICTION}_${BUCKET_NAME}"

    # Build the Access Policy body with jq (proper escaping of dynamic keys).
    local BODY
    BODY=$(jq -n \
        --arg name "$TOKEN_NAME" \
        --arg res "$RESOURCE" \
        --arg w "$CF_R2_PG_BUCKET_ITEM_WRITE" --arg r "$CF_R2_PG_BUCKET_ITEM_READ" '
        {
          name: $name,
          policies: [ {
            effect: "allow",
            resources: { ($res): "*" },
            permission_groups: [ { id: $w }, { id: $r } ]
          } ]
        }')

    local RESP
    RESP=$(curl -s -X POST "${CF_API_BASE}/accounts/${CF_ACCOUNT_ID}/tokens" \
        -H "Authorization: Bearer ${CF_API_BEARER_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "$BODY")

    if [ "$(echo "$RESP" | jq -r '.success')" != "true" ]; then
        echo -e "${C_ERROR}❌ Cloudflare token creation failed:${C_RESET}" >&2
        echo "$RESP" | jq -r '.errors[]? | "   [\(.code)] \(.message)"' >&2
        return 1
    fi

    # S3 credential derivation:
    #   Access Key ID     = token id
    #   Secret Access Key = SHA-256 hex of the raw token value (NO trailing
    #                       newline - $(...) strips it, printf re-emits exactly).
    local TVAL
    CF_SCOPED_TOKEN_ID=$(echo "$RESP" | jq -r '.result.id')
    CF_SCOPED_ACCESS_KEY_ID="$CF_SCOPED_TOKEN_ID"
    TVAL=$(echo "$RESP" | jq -r '.result.value')
    CF_SCOPED_SECRET_ACCESS_KEY=$(printf '%s' "$TVAL" | sha256sum | cut -d' ' -f1)

    return 0
}

# Function: Revoke (delete) a previously minted R2 API token by its id, cleanly
# decommissioning the credential in Cloudflare.
#
#   cloudflare_delete_token <TOKEN_ID>
#
# Returns 0 on success, 1 on any API failure (errors printed to stderr).
function cloudflare_delete_token() {
    local TOKEN_ID=$1

    if [ -z "$TOKEN_ID" ]; then
        echo -e "${C_ERROR}❌ cloudflare_delete_token: a token id is required.${C_RESET}" >&2
        return 1
    fi

    if [[ -z "$CF_API_BEARER_TOKEN" || -z "$CF_ACCOUNT_ID" ]]; then
        echo -e "${C_ERROR}❌ Missing CF_API_BEARER_TOKEN or CF_ACCOUNT_ID.${C_RESET}" >&2
        return 1
    fi

    local RESP
    RESP=$(curl -s -X DELETE "${CF_API_BASE}/accounts/${CF_ACCOUNT_ID}/tokens/${TOKEN_ID}" \
        -H "Authorization: Bearer ${CF_API_BEARER_TOKEN}" \
        -H "Content-Type: application/json")

    if [ "$(echo "$RESP" | jq -r '.success')" != "true" ]; then
        echo -e "${C_ERROR}❌ Cloudflare token deletion failed:${C_RESET}" >&2
        echo "$RESP" | jq -r '.errors[]? | "   [\(.code)] \(.message)"' >&2
        return 1
    fi

    return 0
}

# Function: Revoke a token by NAME instead of id. Used at teardown for the
# app-facing (upload bucket) token, whose id was never stored anywhere local
# to IaCarus - it only ever lived in the Rails app's own credentials. Looks
# the token up by exact name via the account tokens list, then deletes it.
#
#   cloudflare_delete_token_by_name <TOKEN_NAME>
#
# Returns 0 if deleted OR if no matching token was found (already gone is not
# an error). Returns 1 only on an actual Cloudflare API failure.
function cloudflare_delete_token_by_name() {
    local TOKEN_NAME=$1

    if [[ -z "$CF_API_BEARER_TOKEN" || -z "$CF_ACCOUNT_ID" ]]; then
        echo -e "${C_ERROR}❌ Missing CF_API_BEARER_TOKEN or CF_ACCOUNT_ID.${C_RESET}" >&2
        return 1
    fi

    local RESP
    RESP=$(curl -s -X GET "${CF_API_BASE}/accounts/${CF_ACCOUNT_ID}/tokens" \
        -H "Authorization: Bearer ${CF_API_BEARER_TOKEN}" \
        -H "Content-Type: application/json")

    if [ "$(echo "$RESP" | jq -r '.success')" != "true" ]; then
        echo -e "${C_ERROR}❌ Cloudflare token lookup failed:${C_RESET}" >&2
        echo "$RESP" | jq -r '.errors[]? | "   [\(.code)] \(.message)"' >&2
        return 1
    fi

    local FOUND_ID
    FOUND_ID=$(echo "$RESP" | jq -r --arg name "$TOKEN_NAME" '.result[] | select(.name==$name) | .id' | head -n1)

    if [ -z "$FOUND_ID" ]; then
        echo -e "${C_WARN}⚠️  No token named '$TOKEN_NAME' found - already gone.${C_RESET}" >&2
        return 0
    fi

    cloudflare_delete_token "$FOUND_ID"
}

# Function: Revoke EVERY token whose name matches a prefix - either exactly
# equal to it (legacy, pre-timestamp names) or the prefix followed by a '-'
# (the timestamped form vps-rails-app-add.sh mints). Used at teardown for the
# app-facing (upload) tokens, whose ids were never stored locally and which
# may have accumulated across re-provisions / disaster recoveries that reused
# the same app slug. The trailing-dash anchor keeps a prefix like
# 'iacarus-<slug>-upl' from matching a longer sibling type name.
#
#   cloudflare_delete_tokens_by_prefix <PREFIX>
#
# Returns 0 if all matches were deleted OR none were found (already gone is
# not an error). Returns 1 on a lookup failure or if any single deletion fails.
function cloudflare_delete_tokens_by_prefix() {
    local PREFIX=$1

    if [[ -z "$CF_API_BEARER_TOKEN" || -z "$CF_ACCOUNT_ID" ]]; then
        echo -e "${C_ERROR}❌ Missing CF_API_BEARER_TOKEN or CF_ACCOUNT_ID.${C_RESET}" >&2
        return 1
    fi

    local RESP
    RESP=$(curl -s -X GET "${CF_API_BASE}/accounts/${CF_ACCOUNT_ID}/tokens" \
        -H "Authorization: Bearer ${CF_API_BEARER_TOKEN}" \
        -H "Content-Type: application/json")

    if [ "$(echo "$RESP" | jq -r '.success')" != "true" ]; then
        echo -e "${C_ERROR}❌ Cloudflare token lookup failed:${C_RESET}" >&2
        echo "$RESP" | jq -r '.errors[]? | "   [\(.code)] \(.message)"' >&2
        return 1
    fi

    local MATCHES
    MATCHES=$(echo "$RESP" | jq -r --arg p "$PREFIX" \
        '.result[] | select(.name == $p or (.name | startswith($p + "-"))) | "\(.id) \(.name)"')

    if [ -z "$MATCHES" ]; then
        echo -e "${C_WARN}⚠️  No token matching '$PREFIX' found - already gone.${C_RESET}" >&2
        return 0
    fi

    local rc=0 id name
    while IFS=' ' read -r id name; do
        [ -z "$id" ] && continue
        if cloudflare_delete_token "$id"; then
            echo -e "${C_SUCCESS}   ✅ revoked ${name} (${id})${C_RESET}" >&2
        else
            echo -e "${C_ERROR}   ⚠️  failed to revoke ${name} (${id})${C_RESET}" >&2
            rc=1
        fi
    done <<< "$MATCHES"

    return $rc
}

# --- FUNCTIONS R2 (S3 API) ---

# Function: Apply a browser CORS policy to an R2 bucket over the S3 API so a web
# app can PUT/GET objects directly (e.g. presigned uploads from a Rails front
# end). put-bucket-cors REPLACES the bucket's entire CORS configuration on every
# call, so this is idempotent - re-running simply re-puts the same policy. Only
# the allowed origin(s) vary; the methods (GET/PUT), headers (*), exposed header
# (ETag) and max-age (3600 s) are fixed to exactly what a direct browser upload
# needs.
#
#   r2_put_bucket_cors <BUCKET> <ORIGIN[,ORIGIN...]>
#
# ORIGIN may be a single origin or a comma-separated list (blanks trimmed).
# Returns 0 on success, 1 on bad input or any aws-cli failure.
function r2_put_bucket_cors() {
    local BUCKET=$1
    local ORIGINS_CSV=$2

    if [[ -z "$BUCKET" || -z "$ORIGINS_CSV" ]]; then
        echo -e "${C_ERROR}❌ r2_put_bucket_cors: a bucket and at least one origin are required.${C_RESET}" >&2
        return 1
    fi

    # Split the comma-separated origins into a JSON array (trim surrounding
    # whitespace, drop empties) - jq builds it so origins are escaped properly.
    local ORIGINS_JSON
    ORIGINS_JSON=$(printf '%s' "$ORIGINS_CSV" \
        | jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length > 0))')

    if [ "$(echo "$ORIGINS_JSON" | jq 'length')" -eq 0 ]; then
        echo -e "${C_ERROR}❌ r2_put_bucket_cors: no valid origin in '$ORIGINS_CSV'.${C_RESET}" >&2
        return 1
    fi

    local CORS_JSON
    CORS_JSON=$(jq -nc --argjson origins "$ORIGINS_JSON" '
        {
          CORSRules: [ {
            AllowedOrigins: $origins,
            AllowedMethods: ["GET", "PUT"],
            AllowedHeaders: ["*"],
            ExposeHeaders: ["ETag"],
            MaxAgeSeconds: 3600
          } ]
        }')

    aws s3api put-bucket-cors \
        --bucket "$BUCKET" \
        --cors-configuration "$CORS_JSON" \
        --endpoint-url "$CF_R2_S3_CLIENT_URL"
}
