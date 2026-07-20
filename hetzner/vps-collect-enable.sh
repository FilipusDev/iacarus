#!/bin/bash

source ../config.sh
source ../utils.sh

# =============================================================================
# Install the SPRINT C sample collector on a box: the script, its systemd timer,
# and its logrotate policy. Fully idempotent - safe to re-run, and re-running is
# how you ship a changed collector.
#
# WHY THIS IS NOT IN CLOUD-INIT (a deliberate deviation from the C1 sketch):
# the collector is ~200 lines of bash. Embedding it in the user-data template
# would mean maintaining two copies that drift silently, and cloud-init is the
# copy you cannot test without minting a box. Shipping it over SSH keeps ONE
# source of truth - hetzner/iacarus-collect.sh - and makes "deploy a fix" the
# same command as "install it the first time". vps-provision.sh points here on
# a fresh box, exactly as it points at vps-mon-setup for a mon box.
#
# Root is required on the box: the collector reads docker and writes under
# /var/log. It runs from a systemd timer as root; nothing here opens a port.
# =============================================================================

# 1. Get Server Details (Sets $SELECTED_NAME)
select_server_interactive

# 2. Pre-Flight Connection Check
if ! check_ssh_access "$SELECTED_NAME"; then
    exit 1
fi

COLLECTOR_SRC="./iacarus-collect.sh"

if [ ! -f "$COLLECTOR_SRC" ]; then
    echo -e "\n${C_ERROR}❌ Cannot find ${COLLECTOR_SRC} - run this from hetzner/.${C_RESET}\n"
    exit 1
fi

echo -e "\n📈 Installing the collector on ${C_INFO}$SELECTED_NAME${C_RESET}..."
echo "----------------------------------------"

# 3. Ship the collector itself. Piped through `sudo tee` rather than scp because
#    the destination needs root and the ssh alias logs in as a normal user.
if ! ssh -q "$SELECTED_NAME" 'sudo tee /usr/local/bin/iacarus-collect > /dev/null && sudo chmod 0755 /usr/local/bin/iacarus-collect' < "$COLLECTOR_SRC"; then
    echo -e "\n${C_ERROR}❌ Could not install /usr/local/bin/iacarus-collect.${C_RESET}\n"
    exit 1
fi

echo -e "   ${C_SUCCESS}✅ /usr/local/bin/iacarus-collect${C_RESET}"

# 4. Units + rotation + first sample. The interval and retention come from
#    config.sh, so the box is configured by the repo rather than by hand.
ssh -q -t "$SELECTED_NAME" \
    "COLLECT_DIR='${MON_COLLECT_DIR}' \
     INTERVAL='${MON_COLLECT_INTERVAL}' \
     RETAIN='${MON_COLLECT_RETAIN_DAYS}' \
     bash -s" << 'EOF'

G='\033[1;32m'
Y='\033[1;38;5;226m'
R='\033[1;31m'
N='\033[0m'

sudo mkdir -p "$COLLECT_DIR" /var/lib/iacarus /etc/iacarus

# --- systemd service (oneshot: it takes ONE sample and exits) ---------------
sudo tee /etc/systemd/system/iacarus-collect.service > /dev/null << UNIT
[Unit]
Description=IaCarus - collect one box+app sample
# Docker holds the app containers and kamal-proxy; without it the collector
# still records the box row, so this is ordering, not a hard requirement.
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/iacarus-collect
UNIT

# --- systemd timer ----------------------------------------------------------
# OnUnitActiveSec re-arms from the END of the last run, so a slow sample delays
# the next one rather than overlapping it. Type=oneshot then guarantees systemd
# will not start a second collector while one is still going - the natural guard
# against a hung probe piling up processes.
sudo tee /etc/systemd/system/iacarus-collect.timer > /dev/null << UNIT
[Unit]
Description=IaCarus - sample every ${INTERVAL}s

[Timer]
OnBootSec=60s
OnUnitActiveSec=${INTERVAL}s
AccuracySec=1s

[Install]
WantedBy=timers.target
UNIT

# --- logrotate --------------------------------------------------------------
# No copytruncate: the collector opens, appends and closes on every run, so it
# holds no descriptor across a rotation and plain rename-based rotation is safe.
sudo tee /etc/logrotate.d/iacarus > /dev/null << ROT
${COLLECT_DIR}/*.tsv {
    daily
    rotate ${RETAIN}
    compress
    delaycompress
    missingok
    notifempty
    create 0644 root root
}
ROT

sudo systemctl daemon-reload
sudo systemctl enable --now iacarus-collect.timer > /dev/null 2>&1

# Prime one sample immediately so the box is not blank until the first tick -
# and so any breakage surfaces HERE rather than silently 30 seconds later.
sudo systemctl start iacarus-collect.service

# --- verify -----------------------------------------------------------------
if ! systemctl is-active --quiet iacarus-collect.timer; then
    echo -e "${R}❌ iacarus-collect.timer is not active.${N}"
    exit 1
fi

sleep 1

if [ ! -s "${COLLECT_DIR}/box.tsv" ]; then
    echo -e "${R}❌ Timer is active but ${COLLECT_DIR}/box.tsv is empty.${N}"
    echo -e "${R}   Check 'journalctl -u iacarus-collect.service'.${N}"
    exit 1
fi

echo -e "${G}✅ timer active, sampling every ${INTERVAL}s${N}"
echo -e "${G}✅ $(wc -l < "${COLLECT_DIR}/box.tsv") box sample(s) recorded${N}"

if [ -s "${COLLECT_DIR}/apps.tsv" ]; then
    echo -e "${G}✅ $(wc -l < "${COLLECT_DIR}/apps.tsv") app sample(s): $(awk '{print $2}' "${COLLECT_DIR}/apps.tsv" | sort -u | tr '\n' ' ')${N}"
else
    echo -e "${Y}⚠️  No app samples yet - normal if this box runs no apps.${N}"
    echo -e "${Y}   Apps are discovered from kamal-proxy and appear on the next tick.${N}"
fi

echo -e "${Y}   Retention: ${RETAIN} days, rotated daily.${N}"
EOF

RC=$?

echo ""
echo "----------------------------------------"

if [ "$RC" -ne 0 ]; then
    echo -e "${C_ERROR}❌ Collector install failed on ${SELECTED_NAME}.${C_RESET}"
    exit 1
fi

echo -e "${C_SUCCESS}✅ Done.${C_RESET}  Read it with ${C_HIGH}cd mon && make mon-board${C_RESET}"
