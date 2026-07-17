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

if [ "$HAS_DOCKER" = "1" ]; then
    if confirm "Prune unused Docker data (dangling images, stopped containers, networks, build cache)?"; then
        ssh -qn "$SELECTED_NAME" "sudo docker system prune -f"
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
    echo -e "\n${C_ERROR}⚠️  DANGER ZONE${C_RESET} - the next one can delete data."
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
