#!/bin/bash

source ../config.sh
source ../utils.sh

# =============================================================================
# Inspect a box's disk usage, then optionally reclaim space. Inspection is
# READ-ONLY; every cleanup is opt-in behind its own y/N prompt (default No).
#
# Pattern: prompt LOCALLY, act REMOTELY via discrete SSH calls (same shape as
# vps-rails-app-add.sh) - a piped 'bash -s' heredoc can't take y/N input, so
# only the read-only inspection uses one; each cleanup is its own `ssh -n`.
# =============================================================================

# 1. Get Server Details (Sets $SELECTED_NAME)
select_server_interactive

# 2. Pre-Flight Connection Check
if ! check_ssh_access "$SELECTED_NAME"; then
    exit 1
fi

# Local y/N prompt, default No. Returns 0 only on an explicit yes.
confirm() {
    local ans
    echo -en "${C_WARN}$1 [y/N]: ${C_RESET}"
    read -r ans
    [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# Free space on / (avail + use%), read fresh from the box each call.
free_root() {
    ssh -qn "$SELECTED_NAME" "df -hP / | awk 'NR==2{print \$4\" free (\"\$5\" used)\"}'"
}

# Is docker present on the box? (all IaCarus boxes ship it, but guard anyway.)
HAS_DOCKER=$(ssh -qn "$SELECTED_NAME" "command -v docker >/dev/null && echo 1 || echo 0")

# How many retained Kamal releases are sitting here as stopped containers?
#
# Read LOCALLY because the cleanup prompts are local, and a prompt that offers to
# delete something should be able to say how many. Identified by LABEL, not by
# name: Kamal stamps every app container with role=web/worker, while accessories
# carry only 'service' (mpl-cloudflared) and kamal-proxy carries neither - so
# 'label=role' selects app releases exactly, on any box, for any app slug.
if [ "$HAS_DOCKER" = "1" ]; then
    LADDER_COUNT=$(ssh -qn "$SELECTED_NAME" \
        "sudo docker ps -a --filter label=role --filter status=exited -q 2>/dev/null | wc -l")
fi
LADDER_COUNT=${LADDER_COUNT:-0}

echo -e "\n🩺 Inspecting ${C_INFO}$SELECTED_NAME${C_RESET}..."
echo "----------------------------------------"

# 3. INSPECT (read-only). No -n here: the heredoc IS this ssh's stdin (-n would
#    redirect it from /dev/null and run an empty script). The heredoc redirect
#    keeps it from touching the parent script's stdin, so later prompts are safe.
ssh -q "$SELECTED_NAME" 'bash -s' << 'EOF'

# Remote Colors
G='\033[1;32m'
Y='\033[1;38;5;226m'
B='\033[38;5;39m'
N='\033[0m'

echo ""
echo -e "${B}💽 Disk usage${N}"
df -hP -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs | awk 'NR==1{next}{printf "   %-18s %5s used of %-5s (%s)\n",$6,$3,$2,$5}'

echo ""
echo -e "${B}📂 Biggest directories under / (top 6, same filesystem)${N}"
sudo du -xhd1 / 2>/dev/null | awk '$2!="/"' | sort -rh | head -6 | sed 's/^/   /'

echo ""
echo -e "${B}🗒️  systemd journal${N}"
journalctl --disk-usage 2>/dev/null | sed 's/^/   /'

if command -v docker >/dev/null 2>&1; then
    echo ""
    echo -e "${B}🐳 Docker reclaimable${N}"
    sudo docker system df 2>/dev/null | sed 's/^/   /'

    # The figures above are misleading on a Kamal box and must not stand alone.
    # Docker counts an image referenced ONLY by a stopped container as
    # reclaimable, so a healthy rollback ladder reports as "100% reclaimable"
    # gigabytes - free space, right above a prompt offering to reclaim it.
    # Name what that number actually is before anyone is asked to spend it.
    LADDER=$(sudo docker ps -a --filter label=role --filter status=exited \
                --format '{{.Names}}|{{.Status}}' 2>/dev/null)

    if [ -n "$LADDER" ]; then
        echo ""
        echo -e "${B}🔄 Kamal rollback ladder${N}"
        echo -e "   $(printf '%s\n' "$LADDER" | grep -c .) retained release(s) - these are STOPPED CONTAINERS,"
        echo -e "   so a blanket 'docker system prune' would delete them."
        printf '%s\n' "$LADDER" | awk -F'|' 'NF{n=$1; if(length(n)>34) n=substr(n,1,34)"…"; printf "   %-36s %s\n", n, $2}'
    fi
fi

echo ""
echo -e "${B}📦 apt cache${N}"
echo -e "   $(sudo du -sh /var/cache/apt/archives 2>/dev/null | cut -f1) in /var/cache/apt/archives"
AUTORM=$(apt-get -s autoremove 2>/dev/null | grep -c '^Remv')
echo -e "   ${AUTORM} package(s) autoremovable"

echo ""
echo -e "${B}🐧 Kernels${N}"
KCOUNT=$(dpkg -l 'linux-image-*' 2>/dev/null | grep -c '^ii')
echo -e "   ${KCOUNT} installed  (running: $(uname -r))"

echo ""
echo -e "${B}🌡️  /tmp${N}"
echo -e "   $(sudo du -sh /tmp 2>/dev/null | cut -f1) in /tmp"
EOF

echo ""
echo "----------------------------------------"

# Snapshot free space before any cleanup so we can show the win afterwards.
BEFORE=$(free_root)

# 4. CLEANUP (guided - nothing runs unless you say yes)
echo -e "\n🧹 ${C_INFO}Cleanup${C_RESET} - each step is opt-in (default No)."

# 'docker system prune' is deliberately NOT used here. It bundles two very
# different things behind a single yes: reclaiming dangling images, unused
# networks and build cache (free - nothing depends on them), and deleting every
# stopped container (on a Kamal box, the entire rollback ladder). Sharing one
# keystroke between the harmless and the destructive is the bug; the split below
# is the fix. Stopped containers now have their own gate in the danger zone.
if [ "$HAS_DOCKER" = "1" ]; then
    if confirm "Prune dangling images, unused networks and build cache? (keeps every container)"; then
        ssh -qn "$SELECTED_NAME" \
            "sudo docker image prune -f && sudo docker network prune -f && sudo docker builder prune -f"
    fi
fi

if confirm "Vacuum the systemd journal down to the last 7 days?"; then
    ssh -qn "$SELECTED_NAME" "sudo journalctl --vacuum-time=7d"
fi

if confirm "Clean the apt cache and autoremove orphaned packages?"; then
    ssh -qn "$SELECTED_NAME" "sudo apt-get clean && sudo DEBIAN_FRONTEND=noninteractive apt-get autoremove -y"
fi

# Extra-guarded: pruning Docker volumes can DELETE app data. Default OFF, and
# it takes two explicit confirmations before anything happens.
if [ "$HAS_DOCKER" = "1" ]; then
    echo -e "\n${C_ERROR}⚠️  DANGER ZONE${C_RESET} - the next ones can delete data."

    # Stopped containers, gated separately and only when there is a ladder to
    # lose. The cost is NOT data: the images survive (they are tagged, so an
    # image prune leaves them), and the app keeps running. What is lost is the
    # INSTANT rollback - 'kamal rollback' checks that the container for a version
    # still exists (cli/main.rb, container_available?) and refuses the version
    # outright if it does not, turning a zero-download restart into a redeploy.
    if [ "$LADDER_COUNT" -gt 0 ]; then
        echo -e "${C_INFO}   ${LADDER_COUNT} stopped release container(s) present - Kamal's rollback ladder.${C_RESET}"
        echo -e "${C_INFO}   Deleting them loses no data, but 'kamal rollback' stops being instant.${C_RESET}"
        if confirm "Delete ALL stopped containers, including those ${LADDER_COUNT} release(s)?"; then
            ssh -qn "$SELECTED_NAME" "sudo docker container prune -f"
        fi
    fi
    if confirm "Prune unused Docker VOLUMES? (can DELETE app data - e.g. an app's SQLite volume)"; then
        if confirm "Are you absolutely sure? This is irreversible"; then
            ssh -qn "$SELECTED_NAME" "sudo docker volume prune -f"
        else
            echo -e "${C_INFO}   Skipped volume prune.${C_RESET}"
        fi
    fi
fi

# 5. Before/after free space so the win is obvious.
AFTER=$(free_root)
echo ""
echo "----------------------------------------"
echo -e "${C_SUCCESS}✅ Done.${C_RESET}  Free on / :"
echo -e "   before: ${C_HIGH}$BEFORE${C_RESET}"
echo -e "   after : ${C_HIGH}$AFTER${C_RESET}"
echo "----------------------------------------"
