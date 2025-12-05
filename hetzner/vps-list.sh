#!/bin/bash

set -e

source ../config.sh
source ../utils.sh

echo -e "\n${C_INFO}🔍 Fetching server list...${C_RESET}"

# 1. Count existing servers (suppressing headers)
SERVER_COUNT=$(hcloud server list -o noheader | wc -l)

# 2. Conditional Output
if [ "$SERVER_COUNT" -eq 1 ]; then
    echo -e "${C_WARN}🤷 No active servers found.${C_RESET}"
else
    hcloud server list -o columns=id,name,ipv4,datacenter,status
fi
