#!/bin/bash

# =============================================================================
# 📊 REMOTE sar WINDOW PARSERS - shared by the box-stats readers
#
# ⚠️  THIS FILE IS NEVER SOURCED LOCALLY. Every function here runs ON THE BOX,
# so the file is CONCATENATED ONTO THE FRONT OF THE ssh HEREDOC and executed by
# the remote `bash -s` - see the `stats_remote_payload` usage in vps-stats.sh:
#
#     { cat ./lib-stats.sh; cat << 'EOF'
#     ... your remote body, calling cpu_win/mem_win/... ...
#     EOF
#     } | ssh -q "$HOST" 'bash -s'
#
# Consequences that matter when editing:
#   - NO local variables from config.sh/utils.sh exist here ($C_* included).
#     Define what you need, or take it as an argument.
#   - It must be pure bash + coreutils that a hardened Ubuntu 24.04 box has.
#     Nothing here may assume the viewer's toolchain.
#   - Keep it side-effect free at load time apart from the HAS_SAR probe below:
#     it is pasted in ahead of the caller's body on EVERY invocation.
#
# Column positions are pinned to Ubuntu 24.04's sysstat (12.6), but resolved by
# matching the header FIELD NAME rather than a fixed index, so minor layout
# drift between sysstat releases does not silently shift a column.
# =============================================================================

# Does this box have history at all? Callers render '-' cells when it doesn't,
# rather than failing - a box without sysstat still has load/mem/disk/top.
HAS_SAR=0
command -v sar > /dev/null 2>&1 && HAS_SAR=1

# Emit sar text for a window, spanning YESTERDAY's day-file when the lookback
# crosses local midnight. `sar -s` only filters within a single day's file, so
# right after midnight a 1h (or wider) lookback lands on a start time that
# doesn't exist in today's file -> no rows. When the window wraps, we read
# yesterday's tail (from $start) then today's head (00:00 -> now) and let the
# callers' awk average across both. Missing/rotated yesterday file -> that sar
# call errors to /dev/null and we degrade to today-only, never failing.
sar_span() {  # $1=sar flags  $2=start HH:MM:SS  $3=lookback day-of-month  $4=today day-of-month
    if [ "$3" != "$4" ]; then
        LC_ALL=C sar $1 -f /var/log/sysstat/sa"$3" -s "$2" 2>/dev/null
        LC_ALL=C sar $1 2>/dev/null
    else
        LC_ALL=C sar $1 -s "$2" 2>/dev/null
    fi
}

# Average of a named sar field over the last N minutes. Finds the field's column
# from the header row, then count-weights the numeric data rows across whatever
# sar_span emits (one or two day-files) - we compute our own mean instead of
# trusting a single Average: line, which can't span the midnight boundary.
sar_avg() {  # $1=minutes  $2=sar flags  $3=field header (e.g. %memused)
    [ "$HAS_SAR" -eq 1 ] || return 0
    local start today ago
    start=$(date -d "$1 minutes ago" +%H:%M:%S)
    today=$(date +%d); ago=$(date -d "$1 minutes ago" +%d)
    sar_span "$2" "$start" "$ago" "$today" | awk -v want="$3" '
        idx==0 { for (i=1;i<=NF;i++) if ($i==want) idx=i; next }
        idx>0 && $1 ~ /^[0-9:]+$/ && $idx ~ /^[0-9]+(\.[0-9]+)?$/ { s+=$idx; n++ }
        END { if (n>0) printf "%.2f", s/n }'
}

# CPU busy% = 100 - %idle, over the last N minutes.
cpu_win() { local v; v=$(sar_avg "$1" "-u" "%idle"); [ -n "$v" ] && awk -v i="$v" 'BEGIN{printf "%.0f",100-i}'; }
# Memory used% over the last N minutes.
mem_win() { sar_avg "$1" "-r" "%memused" | awk '{printf "%.0f",$1}'; }
# Disk transfers/s (tps) over the last N minutes.
tps_win() { sar_avg "$1" "-b" "tps" | awk '{printf "%.0f",$1}'; }

# Per-iface network average (rxkB/s or txkB/s) over the last N minutes.
# Same count-weighted, midnight-spanning approach as sar_avg, filtered to $ifc.
net_win() {  # $1=minutes  $2=iface  $3=field (rxkB/s|txkB/s)
    [ "$HAS_SAR" -eq 1 ] || return 0
    local start today ago
    start=$(date -d "$1 minutes ago" +%H:%M:%S)
    today=$(date +%d); ago=$(date -d "$1 minutes ago" +%d)
    sar_span "-n DEV" "$start" "$ago" "$today" | awk -v want="$3" -v ifc="$2" '
        idx==0 { for (i=1;i<=NF;i++){ if ($i==want) idx=i; if ($i=="IFACE") ifx=i }; next }
        idx>0 && $1 ~ /^[0-9:]+$/ && $ifx==ifc && $idx ~ /^[0-9]+(\.[0-9]+)?$/ { s+=$idx; n++ }
        END { if (n>0) printf "%.1f", s/n }'
}

# "now" via a 1-second live sample - works even with no history.
cpu_now() { LC_ALL=C sar -u 1 1 2>/dev/null | awk '/^Average:/{printf "%.0f",100-$NF}'; }
tps_now() { LC_ALL=C sar -b 1 1 2>/dev/null | awk '/^Average:/{printf "%.0f",$2}'; }
net_now() { LC_ALL=C sar -n DEV 1 1 2>/dev/null | awk -v ifc="$1" -v want="$2" '
        idx==0 { for (i=1;i<=NF;i++){ if ($i==want) idx=i; if ($i=="IFACE") ifx=i } }
        /^Average:/ && idx>0 && $ifx==ifc { printf "%.1f",$idx; exit }'; }

# Fixed-width table cell; an empty value (no history yet) renders as '-'.
cell() { [ -n "$1" ] && printf "%7s" "$1" || printf "%7s" "-"; }

# The default-route interface, which is what the net rows report on.
default_iface() {
    local ifc
    ifc=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    [ -z "$ifc" ] && ifc="eth0"
    echo "$ifc"
}
