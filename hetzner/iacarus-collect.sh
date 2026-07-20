#!/bin/bash

# =============================================================================
# 📈 iacarus-collect - ONE sample of box + app metrics, appended as TSV.
#
# ⚠️  THIS RUNS ON THE BOX, never on the viewer. It is installed to
# /usr/local/bin/iacarus-collect by cloud-init (fresh boxes) or by
# `make vps-collect-enable` (existing ones), and fired by a systemd timer every
# MON_COLLECT_INTERVAL seconds. It has NO access to config.sh, utils.sh, the
# colour palette, or the registry - everything it needs is baked in at install
# time or discovered locally.
#
# NOT `set -e`: a down app, an unreachable health endpoint and a container that
# vanished mid-deploy are all SIGNALS to be recorded, not reasons to abort. A
# collector that dies on the first failure stops collecting exactly when the
# data matters most. Failures are written as values ('down', '-'), never as an
# absent row.
#
# Writes two files with two FIXED schemas. Mixing record shapes in one file is
# what makes a TSV unreadable six months later:
#
#   box.tsv    ts  cpu_pct  mem_pct  disk_pct  load1
#   apps.tsv   ts  app  state  code  ms  cpu_pct  mem_mb  restarts  uptime_s
#
# Missing values are a literal '-' so column count is invariant - awk on the
# reader side can index positionally without guarding every field.
# =============================================================================

COLLECT_DIR="${MON_COLLECT_DIR:-/var/log/iacarus}"
STATE_DIR="${MON_COLLECT_STATE_DIR:-/var/lib/iacarus}"
HEALTH_PATH="${MON_COLLECT_HEALTH_PATH:-/up}"
TIMEOUT="${MON_COLLECT_TIMEOUT:-5}"

# Where kamal-proxy answers. It publishes :80 on every iacarus box, so this is
# effectively a constant - but naming it keeps the probe honest if the proxy
# ever moves, and lets the collector be exercised against a fixture without
# needing to bind a privileged port.
PROXY_BASE="${MON_COLLECT_PROXY_BASE:-http://127.0.0.1}"

# Per-box overrides. The fleet default is convention (every app is stamped from
# _template_rails-app, which serves Rails 8's '/up'); this is the escape hatch
# for the app that ever differs, without changing the default for everyone.
#   HEALTH_PATH=/healthz          # whole box
#   HEALTH_PATH_myapp=/status     # one app
[ -r /etc/iacarus/collect.conf ] && . /etc/iacarus/collect.conf

mkdir -p "$COLLECT_DIR" "$STATE_DIR"

BOX_TSV="${COLLECT_DIR}/box.tsv"
APPS_TSV="${COLLECT_DIR}/apps.tsv"
TS=$(date +%s)

# -----------------------------------------------------------------------------
# 1. BOX - sampled from /proc, not from sar.
#
# sar samples every 2 minutes (SPRINT A0's timer drop-in); this samples every
# 30s. Rendering both in one table would put two resolutions in adjacent rows,
# so the board owns its own hardware series and sar keeps serving vps-stats'
# longer windows. See SPRINT C, "Hardware sampling".
# -----------------------------------------------------------------------------

# CPU needs TWO reads separated in time: /proc/stat carries cumulative jiffies
# since boot, so a single read gives a lifetime average, not a rate. Each run is
# a fresh process, so the previous counters are persisted and diffed. The first
# run after boot has no predecessor and MUST report '-' - a fabricated 0 would
# read as "idle" on a freshly booted box, exactly when someone is looking.
CPU_PCT="-"
read -r _ u n s i w irq sirq st _ < /proc/stat
CPU_TOTAL=$(( u + n + s + i + w + irq + sirq + st ))
CPU_IDLE=$(( i + w ))

if [ -r "${STATE_DIR}/prev-stat" ]; then
    read -r PREV_TOTAL PREV_IDLE < "${STATE_DIR}/prev-stat"
    D_TOTAL=$(( CPU_TOTAL - PREV_TOTAL ))
    D_IDLE=$(( CPU_IDLE - PREV_IDLE ))
    # A counter reset (reboot) makes the delta negative or zero; report '-'
    # rather than a nonsense percentage.
    if [ "$D_TOTAL" -gt 0 ] && [ "$D_IDLE" -ge 0 ]; then
        CPU_PCT=$(awk -v t="$D_TOTAL" -v idl="$D_IDLE" 'BEGIN{printf "%.1f", (t-idl)*100/t}')
    fi
fi
echo "$CPU_TOTAL $CPU_IDLE" > "${STATE_DIR}/prev-stat"

# MemAvailable (not MemFree) is the kernel's own estimate of what a new workload
# could claim - it counts reclaimable page cache, which MemFree does not. Using
# MemFree here would report a healthy box as permanently near-full.
MEM_PCT=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{if(t>0) printf "%.1f", (t-a)*100/t; else print "-"}' /proc/meminfo)

DISK_PCT=$(df -P / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')
[ -z "$DISK_PCT" ] && DISK_PCT="-"

LOAD1=$(awk '{print $1}' /proc/loadavg 2>/dev/null)
[ -z "$LOAD1" ] && LOAD1="-"

printf '%s\t%s\t%s\t%s\t%s\n' "$TS" "$CPU_PCT" "$MEM_PCT" "$DISK_PCT" "$LOAD1" >> "$BOX_TSV"

# -----------------------------------------------------------------------------
# 2. APPS - discovered from kamal-proxy, probed through it on loopback.
# -----------------------------------------------------------------------------

command -v docker > /dev/null 2>&1 || exit 0

# kamal-proxy has NO machine-readable output mode (its only flag is -h) and
# colours its table even when stdout is not a TTY, so this scrapes a padded
# human table. That is a real dependency risk, and the mitigation is to be LOUD:
# a parse that yields nothing when the proxy is running must not look identical
# to "this box has no apps". No field in the table contains a space, so awk on
# whitespace is safe once the escape codes are stripped.
PROXY_RAW=$(docker exec kamal-proxy kamal-proxy list 2>/dev/null | sed -E 's/\x1b\[[0-9;]*[mK]//g')
PROXY_RC=$?

if [ "$PROXY_RC" -ne 0 ]; then
    # kamal-proxy absent is normal (a box with no apps yet). Record nothing and
    # leave; the box series above is still written.
    exit 0
fi

# Header row is 'Service Host Path Target State TLS'; skip it and blanks.
APP_ROWS=$(printf '%s\n' "$PROXY_RAW" | awk 'NF && $1!="Service"')

if [ -z "$APP_ROWS" ]; then
    exit 0
fi

# One docker stats call for EVERY container, never one per app. Keyed by short
# id, which is exactly what kamal-proxy's Target column carries.
#
# MEASURED ON A REAL BOX: `docker stats --no-stream` costs ~2.0s on its own,
# against ~0.15s for everything else in this script combined. It samples over an
# internal window, so that cost is FIXED - it does not shrink with fewer
# containers. At a 30s tick that is ~6.7% of a core burned continuously, forever,
# just to observe. Too much for a shared-vCPU box.
#
# So container stats are sampled every Nth tick (default 4 -> every 2 minutes)
# while liveness and latency stay at full resolution, because those are what a
# short outage hides in. Skipped ticks write '-', which the reader already skips
# rather than averaging in - so windows stay CORRECT, just computed over fewer
# points, and "now" falls back to the last real measurement.
#
# Deliberately not solved by lengthening the whole interval: that would trade
# away outage resolution to fix a cost that only one command causes.
STATS_EVERY="${MON_COLLECT_STATS_EVERY:-4}"
TICK=0
[ -r "${STATE_DIR}/tick" ] && read -r TICK < "${STATE_DIR}/tick" 2>/dev/null
TICK=$(( (TICK + 1) % STATS_EVERY ))
echo "$TICK" > "${STATE_DIR}/tick"

STATS=""
if [ "$TICK" -eq 0 ]; then
    STATS=$(docker stats --no-stream --format '{{.ID}}\t{{.CPUPerc}}\t{{.MemUsage}}' 2>/dev/null)
fi

# Human-readable byte size -> MB. docker prints '118MiB / 1.9GiB'; only the
# first operand matters.
to_mb() {
    printf '%s' "$1" | awk '
        {
            v = $0
            sub(/[A-Za-z]+$/, "", v)
            unit = $0
            sub(/^[0-9.]+/, "", unit)
            if      (unit ~ /^GiB/) printf "%.0f", v * 1024
            else if (unit ~ /^MiB/) printf "%.0f", v
            else if (unit ~ /^KiB/) printf "%.1f", v / 1024
            else if (unit ~ /^B/)   printf "%.2f", v / 1048576
            else printf "-"
        }'
}

while IFS= read -r ROW; do
    [ -z "$ROW" ] && continue

    SERVICE=$(printf '%s' "$ROW" | awk '{print $1}')
    HOST=$(printf '%s' "$ROW" | awk '{print $2}')
    TARGET=$(printf '%s' "$ROW" | awk '{print $4}')

    # 'mpl-web' -> 'mpl'. Trailing role suffix only; a service with no dash is
    # left alone, so this never mangles a single-token name.
    APP="${SERVICE%-*}"
    CID="${TARGET%%:*}"

    # Per-app health path override, e.g. HEALTH_PATH_mpl=/status. Dashes are not
    # valid in a shell variable name, so they become underscores.
    APP_VAR="HEALTH_PATH_$(printf '%s' "$APP" | tr '-' '_')"
    APP_PATH="${!APP_VAR:-$HEALTH_PATH}"

    # Probe THROUGH kamal-proxy on loopback: it exercises proxy + app together,
    # and the Host header survives redeploys where the container IP does not.
    # %{time_starttransfer} is TTFB in seconds; the board wants integer ms.
    PROBE=$(curl -o /dev/null -s \
                 -w '%{http_code} %{time_starttransfer}' \
                 -H "Host: ${HOST}" \
                 --max-time "$TIMEOUT" \
                 "${PROXY_BASE}${APP_PATH}" 2>/dev/null)

    CODE=$(printf '%s' "$PROBE" | awk '{print $1}')
    MS=$(printf '%s' "$PROBE" | awk '{if (NF>1) printf "%.0f", $2*1000; else print "-"}')
    [ -z "$CODE" ] && CODE="000"
    [ -z "$MS" ] && MS="-"

    # 2xx/3xx is up. Everything else - including 000, curl's "no answer at all"
    # - is down, and the code is retained so a 502 is distinguishable from a
    # timeout when reading the series back.
    case "$CODE" in
        2??|3??) STATE="up" ;;
        *)       STATE="down" ;;
    esac

    CPU_APP="-"; MEM_APP="-"
    if [ -n "$CID" ] && [ -n "$STATS" ]; then
        LINE=$(printf '%s\n' "$STATS" | awk -F'\t' -v id="$CID" '$1==id{print; exit}')
        if [ -n "$LINE" ]; then
            CPU_APP=$(printf '%s' "$LINE" | awk -F'\t' '{gsub(/%/,"",$2); print $2}')
            MEM_RAW=$(printf '%s' "$LINE" | awk -F'\t' '{split($3,a," "); print a[1]}')
            MEM_APP=$(to_mb "$MEM_RAW")
        fi
    fi

    RESTARTS="-"; UPTIME_S="-"
    if [ -n "$CID" ]; then
        INSPECT=$(docker inspect --format '{{.RestartCount}} {{.State.StartedAt}}' "$CID" 2>/dev/null)
        if [ -n "$INSPECT" ]; then
            RESTARTS=$(printf '%s' "$INSPECT" | awk '{print $1}')
            STARTED=$(printf '%s' "$INSPECT" | awk '{print $2}')
            STARTED_EPOCH=$(date -d "$STARTED" +%s 2>/dev/null)
            [ -n "$STARTED_EPOCH" ] && UPTIME_S=$(( TS - STARTED_EPOCH ))
        fi
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$TS" "$APP" "$STATE" "$CODE" "$MS" \
        "${CPU_APP:--}" "${MEM_APP:--}" "${RESTARTS:--}" "${UPTIME_S:--}" >> "$APPS_TSV"

done <<< "$APP_ROWS"

exit 0
