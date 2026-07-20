#!/bin/bash

source ../config.sh
source ../utils.sh

# =============================================================================
# Install the glances SERVER on an EXISTING box so `make mon-hw` can render its
# hardware live (SPRINT B2). Fresh boxes get this from cloud-init (see
# vps-user_data.yml.template); this is the backfill path for boxes provisioned
# before that landed - the same split as sysstat's `make vps-stats-enable`.
#
# ZERO-INGRESS: the server is pinned to 127.0.0.1 by a drop-in we own and NO
# firewall port is opened. The viewer reaches it over an SSH tunnel. Ubuntu's
# package already binds loopback, but that is a packaging default and glances'
# own default is 0.0.0.0 - so we restate it rather than inherit it.
# Fully idempotent - safe to re-run.
# =============================================================================

# 1. Get Server Details (Sets $SELECTED_NAME)
select_server_interactive

# 2. Pre-Flight Connection Check
if ! check_ssh_access "$SELECTED_NAME"; then
    exit 1
fi

echo -e "\n📈 Enabling the glances server on ${C_INFO}$SELECTED_NAME${C_RESET}..."
echo "----------------------------------------"

# 3. Remote install + pin + enable (idempotent)
ssh -q -t "$SELECTED_NAME" "GLANCES_VERSION='${GLANCES_VERSION}' bash -s" << 'EOF'

# Remote Colors
R='\033[1;31m'
G='\033[1;32m'
Y='\033[1;38;5;226m'
N='\033[0m'

# 1. Install glances only if missing
if command -v glances > /dev/null 2>&1; then
    echo -e "${G}✅ glances already installed.${N}"
else
    echo -e "${Y}📦 Installing glances...${N}"
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq glances > /dev/null
    echo -e "${G}✅ Installed.${N}"
fi

# 2. Pin the loopback bind in a drop-in WE own, so a package upgrade can never
#    quietly move the server onto the public interface. The empty ExecStart=
#    clears the packaged value first - systemd would otherwise append ours and
#    refuse to start a service carrying two ExecStart lines.
sudo mkdir -p /etc/systemd/system/glances.service.d
sudo tee /etc/systemd/system/glances.service.d/iacarus.conf > /dev/null << 'CONF'
# IaCarus: pin the glances server to the LOOPBACK interface (SPRINT B2).
# Reached over an SSH tunnel ('make mon-hw'), never an open port. No glances
# password by design - whoever can reach 127.0.0.1 already has a shell here.
[Service]
ExecStart=
ExecStart=/usr/bin/glances -s -B 127.0.0.1
Restart=always
RestartSec=5
CONF

# 3. Reload and (re)start under the pinned command line
sudo systemctl daemon-reload
sudo systemctl enable glances > /dev/null 2>&1
sudo systemctl restart glances

# 4. Verify the posture we actually care about: running, and listening ONLY on
#    loopback. A public bind is a hard failure, not a warning - it would mean
#    the box is serving its process list to the internet.
sleep 3

if ! systemctl is-active --quiet glances; then
    echo -e "${R}❌ glances is not active - check 'systemctl status glances'.${N}"
    exit 1
fi

LISTEN=$(sudo ss -tlnp 2>/dev/null | grep 61209 || true)

if [ -z "$LISTEN" ]; then
    echo -e "${R}❌ glances is active but nothing is listening on 61209.${N}"
    exit 1
fi

if echo "$LISTEN" | grep -q '127.0.0.1:61209'; then
    echo -e "${G}✅ glances server listening on 127.0.0.1:61209 (loopback only).${N}"

    # The version the box ended up with is part of the posture, because glances
    # refuses to serve a client on a different MAJOR - so a box that is up and
    # correctly bound can still be unreadable. apt on Ubuntu 24.04 ships the
    # pinned build today; this catches the day it stops (a newer LTS, a backport)
    # without pretending to fix it, since the right response depends on which
    # end should move.
    INSTALLED=$(glances --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+[0-9.]*' | head -n 1)

    if [ -n "$GLANCES_VERSION" ] && [ "$INSTALLED" != "$GLANCES_VERSION" ]; then
        echo -e "${Y}⚠️  This box has glances ${INSTALLED}, but the fleet pins ${GLANCES_VERSION}.${N}"
        echo -e "${Y}   Viewers pinned with 'make mon-glances-pin' will refuse this box"
        echo -e "${Y}   if the MAJOR differs. Re-pin the fleet or this box, deliberately.${N}"
    fi

    echo -e "${Y}   Reach it with 'make mon-hw' - it opens the SSH tunnel for you.${N}"
else
    echo -e "${R}❌ glances is NOT bound to loopback:${N}"
    echo "$LISTEN"
    echo -e "${R}   Refusing to call this done - the drop-in did not take effect.${N}"
    exit 1
fi
EOF

echo ""
echo "----------------------------------------"
echo -e "${C_SUCCESS}✅ Done.${C_RESET}"
