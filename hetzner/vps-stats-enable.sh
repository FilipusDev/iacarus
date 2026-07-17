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

# 3. Drop the dense (2-min) sampler so short windows have data points
sudo tee /etc/cron.d/iacarus-sysstat > /dev/null << 'CRON'
# IaCarus: dense (2-min) sar sampling so `make vps-stats` can show real
# 5/15/30-min and 1h windows (the packaged sampler is only every 10 min).
MAILTO=""
*/2 * * * * root command -v debian-sa1 > /dev/null && debian-sa1 1 1
CRON

# 4. (Re)start the service and prime the first sample immediately
sudo systemctl enable --now sysstat > /dev/null 2>&1
sudo debian-sa1 1 1 > /dev/null 2>&1 || true

if systemctl is-active --quiet sysstat; then
    echo -e "${G}✅ sysstat active. Sampling every 2 min.${N}"
    echo -e "${Y}   Windows fill in over the next hour - run 'make vps-stats' to watch.${N}"
else
    echo -e "${Y}⚠️  sysstat service is not active - check 'systemctl status sysstat'.${N}"
fi
EOF

echo ""
echo "----------------------------------------"
echo -e "${C_SUCCESS}✅ Done.${C_RESET}"
