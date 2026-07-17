#!/bin/bash

source ../config.sh
source ../utils.sh

# =============================================================================
# READ-ONLY health "sense" of a box across 1/5/15-min (load) and 5/15/30-min +
# 1h (CPU/mem/disk-io/net) windows. Writes NOTHING to the remote host.
#
# Load (1/5/15) is native from /proc/loadavg. The longer windows come from
# sar (sysstat) - enable it on older boxes with `make vps-stats-enable`.
# Column positions are pinned to Ubuntu 24.04's sysstat (12.6).
# =============================================================================

# 1. Get Server Details (Sets $SELECTED_NAME)
select_server_interactive

# 2. Pre-Flight Connection Check
if ! check_ssh_access "$SELECTED_NAME"; then
    exit 1
fi

echo -e "\n📊 Stats for ${C_INFO}$SELECTED_NAME${C_RESET}..."
echo "========================================"

# 3. Remote read-only snapshot
ssh -q -t "$SELECTED_NAME" 'bash -s' << 'EOF'

# Remote Colors
R='\033[1;31m'
G='\033[1;32m'
Y='\033[1;38;5;226m'
B='\033[38;5;39m'
N='\033[0m'

NCPU=$(nproc)
HAS_SAR=0
command -v sar > /dev/null 2>&1 && HAS_SAR=1

# --- helpers -----------------------------------------------------------------

# Average of a named sar field over the last N minutes (today's data file).
# Finds the field's column from the header row, then reads the Average: row.
sar_avg() {  # $1=minutes  $2=sar flags  $3=field header (e.g. %memused)
    [ "$HAS_SAR" -eq 1 ] || return 0
    local start; start=$(date -d "$1 minutes ago" +%H:%M:%S)
    LC_ALL=C sar $2 -s "$start" 2>/dev/null | awk -v want="$3" '
        idx==0 { for (i=1;i<=NF;i++) if ($i==want) idx=i }
        /^Average:/ && idx>0 { print $idx; exit }'
}

# CPU busy% = 100 - %idle, over the last N minutes.
cpu_win() { local v; v=$(sar_avg "$1" "-u" "%idle"); [ -n "$v" ] && awk -v i="$v" 'BEGIN{printf "%.0f",100-i}'; }
# Memory used% over the last N minutes.
mem_win() { sar_avg "$1" "-r" "%memused" | awk '{printf "%.0f",$1}'; }
# Disk transfers/s (tps) over the last N minutes.
tps_win() { sar_avg "$1" "-b" "tps" | awk '{printf "%.0f",$1}'; }

# Per-iface network average (rxkB/s or txkB/s) over the last N minutes.
net_win() {  # $1=minutes  $2=iface  $3=field (rxkB/s|txkB/s)
    [ "$HAS_SAR" -eq 1 ] || return 0
    local start; start=$(date -d "$1 minutes ago" +%H:%M:%S)
    LC_ALL=C sar -n DEV -s "$start" 2>/dev/null | awk -v want="$3" -v ifc="$2" '
        idx==0 { for (i=1;i<=NF;i++){ if ($i==want) idx=i; if ($i=="IFACE") ifx=i } }
        /^Average:/ && idx>0 && $ifx==ifc { printf "%.1f",$idx; exit }'
}

# "now" via a 1-second live sample - works even with no history.
cpu_now() { LC_ALL=C sar -u 1 1 2>/dev/null | awk '/^Average:/{printf "%.0f",100-$NF}'; }
tps_now() { LC_ALL=C sar -b 1 1 2>/dev/null | awk '/^Average:/{printf "%.0f",$2}'; }
net_now() { LC_ALL=C sar -n DEV 1 1 2>/dev/null | awk -v ifc="$1" -v want="$2" '
        idx==0 { for (i=1;i<=NF;i++){ if ($i==want) idx=i; if ($i=="IFACE") ifx=i } }
        /^Average:/ && idx>0 && $ifx==ifc { printf "%.1f",$idx; exit }'; }

cell() { [ -n "$1" ] && printf "%7s" "$1" || printf "%7s" "-"; }

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
IFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
[ -z "$IFACE" ] && IFACE="eth0"

echo ""
printf "   %-14s %7s %7s %7s %7s %7s\n" "window ->" "now" "5m" "15m" "30m" "1h"
printf "   %-14s %s %s %s %s %s\n" "cpu busy %"  "$(cell "$(cpu_now)")" "$(cell "$(cpu_win 5)")"  "$(cell "$(cpu_win 15)")"  "$(cell "$(cpu_win 30)")"  "$(cell "$(cpu_win 60)")"
printf "   %-14s %s %s %s %s %s\n" "mem used %"  "$(cell "$(free | awk '/^Mem:/{printf "%.0f",$3/$2*100}')")" "$(cell "$(mem_win 5)")" "$(cell "$(mem_win 15)")" "$(cell "$(mem_win 30)")" "$(cell "$(mem_win 60)")"
printf "   %-14s %s %s %s %s %s\n" "disk tps"    "$(cell "$(tps_now)")" "$(cell "$(tps_win 5)")" "$(cell "$(tps_win 15)")" "$(cell "$(tps_win 30)")" "$(cell "$(tps_win 60)")"
printf "   %-14s %s %s %s %s %s\n" "net rx kB/s" "$(cell "$(net_now "$IFACE" rxkB/s)")" "$(cell "$(net_win 5 "$IFACE" rxkB/s)")" "$(cell "$(net_win 15 "$IFACE" rxkB/s)")" "$(cell "$(net_win 30 "$IFACE" rxkB/s)")" "$(cell "$(net_win 60 "$IFACE" rxkB/s)")"
printf "   %-14s %s %s %s %s %s\n" "net tx kB/s" "$(cell "$(net_now "$IFACE" txkB/s)")" "$(cell "$(net_win 5 "$IFACE" txkB/s)")" "$(cell "$(net_win 15 "$IFACE" txkB/s)")" "$(cell "$(net_win 30 "$IFACE" txkB/s)")" "$(cell "$(net_win 60 "$IFACE" txkB/s)")"
echo -e "   ${B}(net iface: ${IFACE}; windows are today's samples)${N}"

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
