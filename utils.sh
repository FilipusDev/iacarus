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
