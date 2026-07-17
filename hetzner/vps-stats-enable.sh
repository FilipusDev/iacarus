#!/bin/bash

source ../config.sh
source ../utils.sh

# =============================================================================
# Enable sysstat (sar) historical collection on an EXISTING box so `make
# vps-stats` can show real 5/15/30-min and 1h windows. Fresh boxes get this
# from cloud-init (see vps-user_data.yml.template); this is the backfill path
# for boxes provisioned before that landed. Fully idempotent - safe to re-run.
# =============================================================================

# 1. Get Server Details (Sets $SELECTED_NAME)
select_server_interactive

# 2. Pre-Flight Connection Check
if ! check_ssh_access "$SELECTED_NAME"; then
    exit 1
fi

echo -e "\n📈 Enabling sysstat on ${C_INFO}$SELECTED_NAME${C_RESET}..."
echo "----------------------------------------"

# 3. Remote install + enable (idempotent)
ssh -q -t "$SELECTED_NAME" 'bash -s' << 'EOF'

# Remote Colors
G='\033[1;32m'
Y='\033[1;38;5;226m'
N='\033[0m'

# 1. Install sysstat only if missing
if command -v sar > /dev/null 2>&1; then
    echo -e "${G}✅ sysstat already installed.${N}"
else
    echo -e "${Y}📦 Installing sysstat...${N}"
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sysstat > /dev/null
    echo -e "${G}✅ Installed.${N}"
fi

# 2. Turn on collection
sudo sed -i 's/^ENABLED=.*/ENABLED="true"/' /etc/default/sysstat

# 3. Speed up the collector to every 2 min so short windows have data points.
#    On Ubuntu 24.04 sampling is driven by the sysstat-collect.timer, NOT cron
#    (debian-sa1 self-suppresses under systemd), so we override the TIMER. The
#    empty OnCalendar= first clears the packaged 10-min value.
sudo rm -f /etc/cron.d/iacarus-sysstat   # remove the old, non-working cron file
sudo mkdir -p /etc/systemd/system/sysstat-collect.timer.d
sudo tee /etc/systemd/system/sysstat-collect.timer.d/iacarus.conf > /dev/null << 'CONF'
[Timer]
OnCalendar=
OnCalendar=*:00/02
CONF

# 4. Reload, (re)start the timer, and prime the first sample immediately
sudo systemctl daemon-reload
sudo systemctl enable --now sysstat-collect.timer > /dev/null 2>&1
sudo systemctl start sysstat-collect.service > /dev/null 2>&1 || true

if systemctl is-active --quiet sysstat-collect.timer; then
    echo -e "${G}✅ sysstat collecting every 2 min (systemd timer).${N}"
    echo -e "${Y}   Windows fill in over the next ~10 min - run 'make vps-stats' to watch.${N}"
else
    echo -e "${Y}⚠️  sysstat-collect.timer is not active - check 'systemctl status sysstat-collect.timer'.${N}"
fi
EOF

echo ""
echo "----------------------------------------"
echo -e "${C_SUCCESS}✅ Done.${C_RESET}"
