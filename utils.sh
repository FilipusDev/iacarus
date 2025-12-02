#!/bin/bash

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

# Function: Interactive Server Selection
function select_server_interactive() {
    echo -e "${C_INFO}🔍 Fetching server list from Hetzner...${C_RESET}"

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
