#!/bin/bash

source ../config.sh
source ../utils.sh

# 1. Get Server Details (Sets $SELECTED_NAME)
select_server_interactive

# 2. Pre-Flight Connection Check
if ! check_ssh_access "$SELECTED_NAME"; then
    exit 1
fi

echo -e "\n🩺 Starting Health Check on ${C_INFO}$SELECTED_NAME${C_RESET}..."
echo "----------------------------------------"

# 3. Remote Check
ssh -q -t "$SELECTED_NAME" 'bash -s' << 'EOF'

# Remote Colors
R='\033[1;31m'
G='\033[1;32m'
Y='\033[1;38;5;226m'
N='\033[0m'

echo ""
echo "🔍 1. Cloud-Init Status"
# Capture the output status string (e.g., "status: done", "status: running")
CI_STATUS=$(cloud-init status 2>&1)
if [[ "$CI_STATUS" == *"status: done"* ]]; then
    echo -e "${G}✅ Finished.${N}"
elif [[ "$CI_STATUS" == *"status: running"* ]]; then
    echo -e "${Y}⏳ Still Provisioning (apt upgrade is likely running)...${N}"
    echo -e "${Y}   (You can tail logs with: tail -f /var/log/cloud-init-output.log)${N}"
elif [[ "$CI_STATUS" == *"status: error"* || "$CI_STATUS" == *"status: degraded"* ]]; then
    echo -e "${Y}⚠️  Finished with warnings/errors.${N}"
    echo -e "${N}   (This is common with apt upgrades. Check logs if things break.)${N}"
else
    echo -e "${R}❌ Unknown State: $CI_STATUS${N}"
fi

echo ""
echo "🔍 2. Docker Permissions"
if docker ps > /dev/null 2>&1; then
    echo -e "${G}✅ OK ($(whoami)).${N}"
else
    echo -e "${R}❌ Permission Denied.${N}"
fi

echo ""
echo "🔍 3. Firewall (UFW)"
# We use standard status (not verbose) for easier parsing
UFW_OUTPUT=$(sudo ufw status)

if echo "$UFW_OUTPUT" | grep -q "Status: active"; then
    echo -e "${G}✅ Active.${N}"

    ROGUE_PORTS=$(echo "$UFW_OUTPUT" | grep "ALLOW" | awk '{print $1}' | grep -v "22")
    if [ -n "$ROGUE_PORTS" ]; then
        echo -e "${R}❌ SECURITY ALERT: Non-SSH ports are OPEN!${N}"
        echo -e "${Y}   You strictly allowed only *22 ports, but found:${N}"
        echo -e "${Y}$ROGUE_PORTS${N}"
    else
        echo -e "${G}✅ Stealth Mode Verified. (Only *22 ports are open)${N}"
    fi
else
    echo -e "${R}❌ INACTIVE.${N}"
fi

echo ""
echo "🔍 4. Fail2Ban"
if systemctl is-active --quiet fail2ban; then
    JAILS=$(sudo fail2ban-client status | grep "Jail list" | sed 's/.*list://' | sed 's/^[[:space:]]//')
    echo -e "${G}✅ Running. Jails: $JAILS${N}"
else
    echo -e "${R}❌ NOT Running.${N}"
fi

echo ""
echo "🔍 5. SSH Runtime Config (sshd -T)"
# We check what SSH is ACTUALLY enforcing, regardless of files
SSH_PORT=$(sudo sshd -T | grep "^port " | awk '{print $2}')
ROOT_LOGIN=$(sudo sshd -T | grep "^permitrootlogin " | awk '{print $2}')
PASS_AUTH=$(sudo sshd -T | grep "^passwordauthentication " | awk '{print $2}')

echo "   Port: $SSH_PORT"

if [ "$ROOT_LOGIN" == "no" ]; then
    echo -e "${G}✅ Root Login Disabled.${N}"
else
    echo -e "${R}❌ Root Login ENABLED!${N}"
fi

if [ "$PASS_AUTH" == "no" ]; then
    echo -e "${G}✅ Password Auth Disabled.${N}"
else
    echo -e "${R}❌ Password Auth ENABLED! (Security Risk)${N}"
fi

echo ""
echo "🔍 6. SSH File Hygiene"
TARGET_DIR="/etc/ssh/sshd_config.d"
EXPECTED_FILE="hardening.conf"

# 1. Verify our file actually exists
if [ ! -f "$TARGET_DIR/$EXPECTED_FILE" ]; then
    echo -e "${R}❌ CRITICAL: '$EXPECTED_FILE' is MISSING!${N}"
    echo -e "${Y}   (Your security settings might not be loaded)${N}"
else
    # 2. Look for any file that is NOT the expected file
    # We use 'find' to look for files (-type f) that do NOT match the name (-not -name)
    ROGUE_FILES=$(find "$TARGET_DIR" -maxdepth 1 -type f -not -name "$EXPECTED_FILE")

    if [ -z "$ROGUE_FILES" ]; then
        echo -e "${G}✅ Clean. (Only '$EXPECTED_FILE' exists)${N}"
    else
        echo -e "${R}❌ POLLUTION DETECTED: Unknown files found!${N}"
        echo -e "${Y}   (Ideally, only '$EXPECTED_FILE' should exist here)${N}"
        # Print the names of the rogue files in Yellow so you see what to delete
        echo -e "--- ROGUE_FILES ---"
        echo -e "$ROGUE_FILES"
        echo -e "-------------------"
    fi
fi

echo ""
echo "🔍 7. Swap"
SWAP_TOTAL=$(free -m | awk '/^Swap:/ {print $2}')
if [ -n "$SWAP_TOTAL" ] && [ "$SWAP_TOTAL" -gt 0 ]; then
    echo -e "${G}✅ Active (${SWAP_TOTAL}MB).${N}"
else
    echo -e "${R}❌ No swap allocated.${N}"
fi

echo ""
echo "🔍 8. Docker Log Rotation"
if [ -f /etc/docker/daemon.json ] && grep -q '"max-size": "10m"' /etc/docker/daemon.json; then
    echo -e "${G}✅ Configured (max-size: 10m).${N}"
else
    echo -e "${R}❌ Missing or misconfigured '/etc/docker/daemon.json'.${N}"
fi

echo ""
echo "🔍 9. Docker Prune Cron"
if [ -x /etc/cron.weekly/docker-prune ]; then
    echo -e "${G}✅ Present & executable.${N}"
else
    echo -e "${R}❌ Missing or not executable '/etc/cron.weekly/docker-prune'.${N}"
fi

# Reboot Check
if [ -f /var/run/reboot-required ]; then
    echo ""
    echo -e "${R}🔄 Reboot REQUIRED. Rebooting in the background...${N}"
    # Detached so this SSH session exits cleanly (0) before the box actually
    # reboots - otherwise `sudo reboot` kills the connection mid-script and
    # the caller's ERR trap misreports the expected reboot as a failure.
    nohup sudo bash -c 'sleep 5 && reboot' > /dev/null 2>&1 &
    disown
else
    echo ""
    echo -e "${G}✅ System is clean (No reboot needed).${N}"
fi


echo ""
echo "----------------------------------------"
EOF
