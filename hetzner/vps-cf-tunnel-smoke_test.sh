#!/bin/bash

source ../config.sh
source ../utils.sh

# 1. Check configuration variables availability
echo -e "${C_INFO}🔍 Checking Pre-requisites...${C_RESET}"
if [ -z "$CF_TUNNEL_SMOKE_TEST_TOKEN" ]; then
    echo -e "${C_ERROR}❌ Error: Missing configuration variables.${C_RESET}"
    exit 1
fi

TOKEN=${CF_TUNNEL_SMOKE_TEST_TOKEN}

# 2. Get Server Details (Sets $SELECTED_NAME)
select_server_interactive

# 3. Pre-Flight Connection Check
if ! check_ssh_access "$SELECTED_NAME"; then
    exit 1
fi

echo -e "\n${C_INFO}🌫️  Starting Smoke Test on${C_RESET}${C_HIGH} '$SELECTED_NAME'${C_RESET}..."
echo "----------------------------------------"

# 4. Remote Execution
ssh -q -t "$SELECTED_NAME" "bash -s" << EOF

# Remote Variables
NETWORK="net-smoke"
APP="smoke-app"
TUNNEL="smoke-tunnel"
TOKEN="$TOKEN"

# Remote Colors
G='\033[1;32m'
B='\033[38;5;39m'
N='\033[0m'

echo -e "\${B}1. Creating Docker Network (\$NETWORK)...\${N}"
docker network create \$NETWORK 2>/dev/null || true

echo -e "\${B}2. Starting Fake App (Nginx)...\${N}"
docker run -d --rm --name \$APP --network \$NETWORK nginx:alpine > /dev/null

echo -e "\${B}3. Starting Tunnel...\${N}"
docker run -d --rm --name \$TUNNEL --network \$NETWORK cloudflare/cloudflared:latest tunnel --no-autoupdate run --token \$TOKEN > /dev/null

echo -e "\n\${G}✅ Simulation Running!\${N}"
echo "   App:     \$APP"
echo "   Tunnel:  \$TUNNEL"
echo "   Network: \$NETWORK"
echo "----------------------------------------"
EOF

# 5. Local Instructions
echo -e "${C_WARN}⚠️  ACTION REQUIRED ON CLOUDFLARE:${C_RESET}"
echo "1. Zero Trust -> Tunnels -> Configure -> Public Hostname"
echo "2. Service Type: HTTP"
echo -e "3. URL: ${C_SUCCESS}http://smoke-app:80${C_RESET}"
echo ""
echo -e "${C_INFO}🌍 Check your browser. Do you see Nginx?${C_RESET}"
read -p "Press [Enter] to clean up and destroy test..."

# 6. Cleanup
echo -e "${C_INFO}🧹 Cleaning up...${C_RESET}"
ssh -q -t "$SELECTED_NAME" "bash -s" << EOF
NETWORK="net-smoke"
APP="smoke-app"
TUNNEL="smoke-tunnel"
docker rm -f \$TUNNEL \$APP 2>/dev/null
docker network rm \$NETWORK 2>/dev/null
docker system prune -af > /dev/null
EOF
echo -e "${C_SUCCESS}✅ Cleaned up!${C_RESET}"
