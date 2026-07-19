#!/bin/bash

# Sourced with a guard: run from anywhere but mon/ and these paths resolve
# outside the repo and fail SILENTLY (the ERR trap lives in utils.sh, which
# hasn't loaded yet either) - leaving the script running with no config and no
# helpers. For a monitoring tool that surfaces as a false "nothing to watch"
# all-clear, which is worse than any error. Fail loudly instead.
if ! source ../config.sh 2>/dev/null || ! source ../utils.sh 2>/dev/null; then
    echo "❌ Could not load ../config.sh + ../utils.sh."
    echo "   Run this from the mon/ directory, or use the Makefile target."
    exit 1
fi

# =============================================================================
# 📡 MON - app liveness + latency board (SPRINT B4)
#
# Iterates mon/registry.json and checks each app's health endpoint over its
# PUBLIC url. Pure sh + curl + jq: no daemon, no database, no web page, and no
# credentials - this runs identically from a laptop or a mon box.
#
# NOT set -e: a failing curl IS the signal here, not an abort condition. Every
# fallible call is guarded so the global ERR trap never fires on a down app.
#
# Usage: make mon-apps              (live board, redraws every MON_REFRESH_SECONDS)
#        ./mon-apps.sh --once       (one pass, then exit - scriptable/CI-friendly)
#        ./mon-apps.sh --interval 5
# =============================================================================

ONCE=0
INTERVAL="$MON_REFRESH_SECONDS"

while [ $# -gt 0 ]; do
    case "$1" in
        --once)     ONCE=1; shift ;;
        --interval) INTERVAL="$2"; shift 2 ;;
        *)
            echo -e "${C_ERROR}❌ Unknown argument '$1'.${C_RESET}"
            echo -e "${C_INFO}   Usage: ./mon-apps.sh [--once] [--interval N]${C_RESET}"
            exit 1
            ;;
    esac
done

# 1. Nothing to watch is a normal state, not an error.
COUNT=$(mon_registry_list | wc -l)

if [ "$COUNT" -eq 0 ]; then
    echo -e "\n${C_WARN}🤷 No apps registered - nothing to watch.${C_RESET}"
    echo -e "${C_INFO}   Run ${C_RESET}${C_HIGH}make mon-register${C_RESET}${C_INFO} to add one.${C_RESET}\n"
    exit 0
fi

# 2. TLS expiry is read ONCE per run, not per redraw: a certificate does not
#    change between refreshes, and probing it costs a second full handshake per
#    app. Cached in a parallel array keyed by row order. openssl is optional -
#    without it the column simply reads '-' rather than failing the board.
declare -a TLS_DAYS

function tls_days_left() {
    local URL=$1

    command -v openssl > /dev/null 2>&1 || { echo ""; return 0; }
    [[ "$URL" == https://* ]] || { echo ""; return 0; }

    local HOST="${URL#https://}"
    HOST="${HOST%%/*}"
    HOST="${HOST%%:*}"

    local END_DATE
    END_DATE=$(echo | timeout 10 openssl s_client -servername "$HOST" -connect "${HOST}:443" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)

    [ -z "$END_DATE" ] && { echo ""; return 0; }

    local END_EPOCH NOW_EPOCH
    END_EPOCH=$(date -d "$END_DATE" +%s 2>/dev/null) || { echo ""; return 0; }
    NOW_EPOCH=$(date +%s)

    echo $(( (END_EPOCH - NOW_EPOCH) / 86400 ))
}

echo -e "\n${C_INFO}🔐 Reading TLS certificate expiry (once)...${C_RESET}"

IDX=0
while read -r ROW; do
    TLS_DAYS[$IDX]=$(tls_days_left "$(echo "$ROW" | jq -r '.base_url')")
    IDX=$((IDX + 1))
done < <(mon_registry_list)

# 3. Column widths from the data, so long names don't wrap the board.
W_NAME=$(mon_registry_list | jq -r '.name' | awk '{ if (length > m) m = length } END { print (m > 4 ? m : 4) }')

# Status is an ANSI-COLOURED '●', not a 🟢/🟡/🔴 emoji, for two reasons found
# the hard way:
#   1. Colour. Emoji carry their own palette from whichever font wins the
#      fontconfig match - and Font Awesome (monochrome) routinely beats Noto
#      Color Emoji for U+1F7E2/E1/E4, rendering every state as an identical
#      grey blob. '●' takes the terminal's own colours, so it cannot lose.
#   2. Width. Emoji are double-width, '●' is single - and a status column whose
#      width depends on font fallback silently skews every column after it.
# Fields are padded to width BEFORE colour codes are wrapped around them:
# printf counts escape sequences as characters and would misalign otherwise.
# Row = '● ' (2) + name (W_NAME) + gap (2) + code (5) + six 8-wide cells (48).
SEP_WIDTH=$(( W_NAME + 57 ))
SEPARATOR=$(printf '%*s' "$SEP_WIDTH" '' | tr ' ' '-')

# 4. Leave the terminal usable on Ctrl-C: show the cursor again and say goodbye
#    rather than dumping the user out mid-redraw with a hidden cursor.
function on_exit() {
    printf '\033[?25h'
    echo ""
    echo -e "${C_INFO}👋 Board stopped.${C_RESET}"
    echo ""
    exit 0
}
trap on_exit INT TERM

# 5. One full pass over the fleet. Sequential on purpose: the fleet is tiny, and
#    serial curls keep the code obvious and the output ordering stable.
#    KNOWN TRADEOFF: a pass costs the SUM of every app's response time, so slow
#    or unreachable apps stretch the whole board - worst case
#    MON_HTTP_TIMEOUT x (number of down apps), which can exceed the refresh
#    interval and make redraws lag. Fine at current fleet size; when it stops
#    being fine, fan the curls out into background jobs and `wait` on them
#    rather than reaching for a daemon.
function draw_board() {
    local NOW
    NOW=$(date '+%Y-%m-%d %H:%M:%S')

    echo -e "${C_HIGH}📡 IaCarus - APP BOARD${C_RESET}  ${C_INFO}${NOW}${C_RESET}"
    echo "$SEPARATOR"
    printf "${C_HIGH}  %-${W_NAME}s  %-5s%8s%8s%8s%8s%8s%8s${C_RESET}\n" \
        "NAME" "CODE" "DNS" "CONN" "TLS" "TTFB" "TOTAL" "CERT"

    local IDX=0
    local DOWN=0
    local CRIT=0
    local WARN=0

    while read -r ROW; do
        local NAME URL TIMING HTTP_CODE
        NAME=$(echo "$ROW" | jq -r '.name')
        URL="$(echo "$ROW" | jq -r '.base_url')$(echo "$ROW" | jq -r '.health_path')"

        # curl emits seconds; every fallible field defaults so a dead host still
        # renders a row instead of blanking the board.
        TIMING=$(curl -s -o /dev/null --max-time "$MON_HTTP_TIMEOUT" \
            -w '%{http_code} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total}' \
            "$URL" 2>/dev/null) || TIMING="000 0 0 0 0 0"

        local CODE T_DNS T_CONN T_TLS T_TTFB T_TOTAL
        read -r CODE T_DNS T_CONN T_TLS T_TTFB T_TOTAL <<< "$TIMING"

        # Convert the cumulative timings curl reports into per-phase deltas, in
        # ms. appconnect is 0 on plain http (no TLS phase) - guard so the TLS
        # column doesn't render a negative number.
        local MS_DNS MS_CONN MS_TLS MS_TTFB MS_TOTAL
        MS_DNS=$(awk -v v="$T_DNS" 'BEGIN { printf "%.0f", v * 1000 }')
        MS_CONN=$(awk -v a="$T_CONN" -v b="$T_DNS" 'BEGIN { d = (a - b) * 1000; printf "%.0f", (d > 0 ? d : 0) }')
        MS_TLS=$(awk -v a="$T_TLS" -v b="$T_CONN" 'BEGIN { d = (a > 0 ? (a - b) * 1000 : 0); printf "%.0f", (d > 0 ? d : 0) }')
        MS_TTFB=$(awk -v a="$T_TTFB" -v b="$T_TLS" -v c="$T_CONN" 'BEGIN { s = (a > 0 ? a : 0); base = (b > 0 ? b : c); d = (s - base) * 1000; printf "%.0f", (d > 0 ? d : 0) }')
        MS_TOTAL=$(awk -v v="$T_TOTAL" 'BEGIN { printf "%.0f", v * 1000 }')

        # Verdict: reachability first, then speed.
        local COLOR
        if [ "$CODE" != "200" ]; then
            COLOR="$C_ERROR"; DOWN=$((DOWN + 1))
            [ "$CODE" = "000" ] && CODE="---"
        elif [ "$MS_TOTAL" -ge "$MON_LATENCY_CRIT_MS" ]; then
            COLOR="$C_ERROR"; CRIT=$((CRIT + 1))
        elif [ "$MS_TOTAL" -ge "$MON_LATENCY_WARN_MS" ]; then
            COLOR="$C_WARN"; WARN=$((WARN + 1))
        else
            COLOR="$C_SUCCESS"
        fi

        # Certificate column, from the once-per-run cache.
        local CERT="${TLS_DAYS[$IDX]}"
        local CERT_TXT CERT_COLOR="$C_INFO"
        if [ -z "$CERT" ]; then
            CERT_TXT="-"
        else
            CERT_TXT="${CERT}d"
            if [ "$CERT" -le 0 ]; then
                CERT_TXT="EXPIRED"; CERT_COLOR="$C_ERROR"
            elif [ "$CERT" -le "$MON_TLS_WARN_DAYS" ]; then
                CERT_COLOR="$C_WARN"
            fi
        fi

        # Pad to width FIRST, colour SECOND - printf counts ANSI escapes as
        # visible characters, so colouring inside the format string skews the
        # columns by the length of every escape sequence.
        local F_NAME F_CODE F_DNS F_CONN F_TLS F_TTFB F_TOTAL F_CERT
        F_NAME=$(printf "%-${W_NAME}s" "$NAME")
        F_CODE=$(printf "%-5s" "$CODE")
        F_DNS=$(printf "%8s" "${MS_DNS}ms")
        F_CONN=$(printf "%8s" "${MS_CONN}ms")
        F_TLS=$(printf "%8s" "${MS_TLS}ms")
        F_TTFB=$(printf "%8s" "${MS_TTFB}ms")
        F_TOTAL=$(printf "%8s" "${MS_TOTAL}ms")
        F_CERT=$(printf "%8s" "$CERT_TXT")

        echo -e "${COLOR}●${C_RESET} ${COLOR}${F_NAME}${C_RESET}  ${COLOR}${F_CODE}${C_RESET}${F_DNS}${F_CONN}${F_TLS}${F_TTFB}${COLOR}${F_TOTAL}${C_RESET}${CERT_COLOR}${F_CERT}${C_RESET}"

        IDX=$((IDX + 1))
    done < <(mon_registry_list)

    echo "$SEPARATOR"

    # Summary line - the bit you read from across the room.
    if [ "$DOWN" -gt 0 ] && [ "$CRIT" -gt 0 ]; then
        echo -e "${C_ERROR}● $DOWN of $COUNT app(s) not answering 200, $CRIT over ${MON_LATENCY_CRIT_MS}ms.${C_RESET}"
    elif [ "$DOWN" -gt 0 ]; then
        echo -e "${C_ERROR}● $DOWN of $COUNT app(s) not answering 200.${C_RESET}"
    elif [ "$CRIT" -gt 0 ]; then
        echo -e "${C_ERROR}● All $COUNT app(s) up, $CRIT over ${MON_LATENCY_CRIT_MS}ms.${C_RESET}"
    elif [ "$WARN" -gt 0 ]; then
        echo -e "${C_WARN}● All $COUNT app(s) up, $WARN slower than ${MON_LATENCY_WARN_MS}ms.${C_RESET}"
    else
        echo -e "${C_SUCCESS}● All $COUNT app(s) healthy.${C_RESET}"
    fi

    # Exposed so the thresholds behind the colours are never a mystery.
    echo -e "  ${C_SUCCESS}●${C_RESET}${C_INFO} <${MON_LATENCY_WARN_MS}ms   ${C_RESET}${C_WARN}●${C_RESET}${C_INFO} <${MON_LATENCY_CRIT_MS}ms   ${C_RESET}${C_ERROR}●${C_RESET}${C_INFO} slower, or not 200${C_RESET}"

    # Status IS the verdict - anything rendered 🔴 fails the pass. Deliberately
    # NOT grepped out of the rendered text: the legend below the table contains
    # a literal 🔴, so a text match reports every healthy board as failing.
    [ $(( DOWN + CRIT )) -gt 0 ] && return 1
    return 0
}

# 6. One pass, or a redraw loop. --once is the scriptable form: it exits
#    non-zero when anything is down, so it can gate a CI step or (SPRINT C) be
#    the thing an alerting cron actually calls.
if [ "$ONCE" -eq 1 ]; then
    echo ""

    # Captured in a condition so the miss path doesn't trip the global ERR trap
    # and print the "Script aborted!" panic over a legitimate red board.
    if OUTPUT=$(draw_board); then
        RC=0
    else
        RC=1
    fi

    echo "$OUTPUT"
    echo ""
    exit $RC
fi

printf '\033[?25l'

while true; do
    BOARD=$(draw_board)

    # Redraw by homing the cursor and clearing to end of screen, rather than
    # `clear`: no flicker, and scrollback survives.
    printf '\033[H\033[J'
    echo ""
    echo "$BOARD"
    echo ""
    echo -e "${C_INFO}↻ refreshing every ${INTERVAL}s · Ctrl-C to stop${C_RESET}"

    sleep "$INTERVAL"
done
