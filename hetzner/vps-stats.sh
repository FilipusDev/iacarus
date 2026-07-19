#!/bin/bash

source ../config.sh
source ../utils.sh

# =============================================================================
# READ-ONLY health "sense" of a box across 1/5/15-min (load) and 5/15/30-min +
# 1h (CPU/mem/disk-io/net) windows. Writes NOTHING to the remote host.
#
# Load (1/5/15) is native from /proc/loadavg. The longer windows come from
# sar (sysstat) - enable it on older boxes with `make vps-stats-enable`.
#
# The sar window parsers themselves live in ./lib-stats.sh, which is PREPENDED
# to the heredoc below and executed by the remote `bash -s` - it is never
# sourced locally, because every one of those functions reads files that only
# exist on the box. See that file's header before editing either side.
# =============================================================================

STATS_LIB="./lib-stats.sh"

# 1. Fail loudly if the parser library is missing. Without it the remote body
#    would run with every window function undefined and render a full table of
#    '-' cells - a box that looks idle rather than a tool that is broken.
if [ ! -f "$STATS_LIB" ]; then
    echo -e "${C_ERROR}❌ Could not find $STATS_LIB.${C_RESET}"
    echo -e "${C_INFO}   Run this from the hetzner/ directory, or use 'make vps-stats'.${C_RESET}"
    exit 1
fi

# 2. Get Server Details (Sets $SELECTED_NAME)
select_server_interactive

# 3. Pre-Flight Connection Check
if ! check_ssh_access "$SELECTED_NAME"; then
    exit 1
fi

echo -e "\n📊 Stats for ${C_INFO}$SELECTED_NAME${C_RESET}..."
echo "========================================"

# 4. Remote read-only snapshot: parser library first, then this script's body,
#    piped as one program into the remote shell.
{ cat "$STATS_LIB"; cat << 'EOF'

# Remote Colors
R='\033[1;31m'
G='\033[1;32m'
Y='\033[1;38;5;226m'
B='\033[38;5;39m'
N='\033[0m'

NCPU=$(nproc)

# --- 1. host + load ----------------------------------------------------------
echo ""
echo -e "🖥️  ${B}$(hostname)${N}  |  up $(uptime -p | sed 's/^up //')  |  ${NCPU} vCPU  |  $(uname -r)"

read L1 L5 L15 _ < /proc/loadavg
# Colour the 1-min load against core count (100% = 1.0 per core).
LCOL=$G
awk -v l="$L1" -v n="$NCPU" 'BEGIN{exit !(l > n)}'        && LCOL=$R
[ "$LCOL" = "$G" ] && awk -v l="$L1" -v n="$NCPU" 'BEGIN{exit !(l > n*0.7)}' && LCOL=$Y
echo -e "   load avg (1/5/15): ${LCOL}${L1}${N} / ${L5} / ${L15}   ${B}(1.0 per core = 100%)${N}"

# --- 2. windows table --------------------------------------------------------
IFACE=$(default_iface)

echo ""
printf "   %-14s %7s %7s %7s %7s %7s\n" "window ->" "now" "5m" "15m" "30m" "1h"
printf "   %-14s %s %s %s %s %s\n" "cpu busy %"  "$(cell "$(cpu_now)")" "$(cell "$(cpu_win 5)")"  "$(cell "$(cpu_win 15)")"  "$(cell "$(cpu_win 30)")"  "$(cell "$(cpu_win 60)")"
printf "   %-14s %s %s %s %s %s\n" "mem used %"  "$(cell "$(free | awk '/^Mem:/{printf "%.0f",$3/$2*100}')")" "$(cell "$(mem_win 5)")" "$(cell "$(mem_win 15)")" "$(cell "$(mem_win 30)")" "$(cell "$(mem_win 60)")"
printf "   %-14s %s %s %s %s %s\n" "disk tps"    "$(cell "$(tps_now)")" "$(cell "$(tps_win 5)")" "$(cell "$(tps_win 15)")" "$(cell "$(tps_win 30)")" "$(cell "$(tps_win 60)")"
printf "   %-14s %s %s %s %s %s\n" "net rx kB/s" "$(cell "$(net_now "$IFACE" rxkB/s)")" "$(cell "$(net_win 5 "$IFACE" rxkB/s)")" "$(cell "$(net_win 15 "$IFACE" rxkB/s)")" "$(cell "$(net_win 30 "$IFACE" rxkB/s)")" "$(cell "$(net_win 60 "$IFACE" rxkB/s)")"
printf "   %-14s %s %s %s %s %s\n" "net tx kB/s" "$(cell "$(net_now "$IFACE" txkB/s)")" "$(cell "$(net_win 5 "$IFACE" txkB/s)")" "$(cell "$(net_win 15 "$IFACE" txkB/s)")" "$(cell "$(net_win 30 "$IFACE" txkB/s)")" "$(cell "$(net_win 60 "$IFACE" txkB/s)")"
echo -e "   ${B}(net iface: ${IFACE}; windows are rolling sar samples)${N}"

if [ "$HAS_SAR" -eq 0 ]; then
    echo ""
    echo -e "   ${Y}⚠️  sysstat not installed - CPU/disk/net rows are unavailable${N}"
    echo -e "   ${Y}   (load, memory, disk space and top still work below).${N}"
    echo -e "   ${Y}   Enable the full picture with: make vps-stats-enable${N}"
fi

# --- 3. memory + swap --------------------------------------------------------
echo ""
echo "🧠 Memory"
free -h | awk '/^Mem:/{printf "   RAM : %s used / %s total  (%s available)\n",$3,$2,$7}
               /^Swap:/{printf "   Swap: %s used / %s total\n",$3,$2}'

# --- 4. disk space -----------------------------------------------------------
echo ""
echo "💽 Disk space"
df -hP -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs 2>/dev/null | awk -v R="$R" -v G="$G" -v Y="$Y" -v N="$N" '
    NR==1 { printf "   %-24s %6s %6s %6s  %s\n","mounted on",$2,$3,$4,"use%"; next }
    {
        u=$5; gsub("%","",u); c=G;
        if (u+0 >= 90) c=R; else if (u+0 >= 70) c=Y;
        printf "   %-24s %6s %6s %6s  %s%s%s\n",$6,$2,$3,$4,c,$5,N
    }'

# --- 5. top processes --------------------------------------------------------
echo ""
echo "🏭 Top processes"
echo -e "   ${B}by CPU:${N}"
ps -eo pcpu,pmem,comm --sort=-pcpu | head -n 4 | tail -n 3 | awk '{printf "     %5s%%cpu  %5s%%mem  %s\n",$1,$2,$3}'
echo -e "   ${B}by MEM:${N}"
ps -eo pcpu,pmem,comm --sort=-pmem | head -n 4 | tail -n 3 | awk '{printf "     %5s%%cpu  %5s%%mem  %s\n",$1,$2,$3}'

echo ""
echo "========================================"
EOF
} | ssh -q -t "$SELECTED_NAME" 'bash -s'
