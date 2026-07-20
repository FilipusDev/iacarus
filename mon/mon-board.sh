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
# 📊 MON - the board: box + app time series, whole fleet on one screen (SPRINT C)
#
# Reads the TSVs the on-box collector writes (hetzner/iacarus-collect.sh) and
# renders them per box, apps nested underneath. Replaces the glances hardware
# board removed in C0.
#
# ARCHITECTURE: aggregation happens ON THE BOX. lib-board.sh is concatenated
# ahead of a remote heredoc and its awk reducers return a few summary lines -
# a week of 30s samples is ~20k lines per file, and shipping that per refresh
# to compute an average would move megabytes per box.
#
# Boxes are queried IN PARALLEL. B4's documented tradeoff was sequential probing,
# where one slow host delays every other; that lesson is applied here rather
# than repeated.
#
# NOT set -e: an unreachable box must degrade to "that one is unreachable",
# never abort the board.
#
# Usage: make mon-board                (one-shot table, all boxes)
#        make mon-board-watch          (live, sparklines)
#        ./mon-board.sh --box NAME     (narrow to one box)
#        ./mon-board.sh --once         (scriptable; non-zero if anything is down)
# =============================================================================

WATCH=0
ONCE=0
ONLY_BOX=""
INTERVAL="$MON_REFRESH_SECONDS"

while [ $# -gt 0 ]; do
    case "$1" in
        --watch)    WATCH=1; shift ;;
        --once)     ONCE=1; shift ;;
        --box)      ONLY_BOX="$2"; shift 2 ;;
        --interval) INTERVAL="$2"; shift 2 ;;
        *)
            echo -e "${C_ERROR}❌ Unknown argument '$1'.${C_RESET}"
            echo -e "${C_INFO}   Usage: ./mon-board.sh [--watch] [--once] [--box NAME] [--interval N]${C_RESET}"
            exit 1
            ;;
    esac
done

# 1. Which boxes? Same rule as every other mon target (see mon_context):
#      operator -> ask Hetzner, so a box with no registered app still appears
#      viewer   -> the registry is all we have
if [ -n "$ONLY_BOX" ]; then
    BOXES=("$ONLY_BOX")
    CONTEXT="explicit"
else
    CONTEXT=$(mon_context)
    if [ "$CONTEXT" = "operator" ]; then
        mapfile -t BOXES < <(hcloud server list -o noheader -o columns=name 2>/dev/null | awk 'NF {print $1}' | sort -u)
    else
        mapfile -t BOXES < <(mon_registry_list | jq -r '.box' 2>/dev/null | sort -u)
    fi
fi

if [ ${#BOXES[@]} -eq 0 ]; then
    echo -e "\n${C_WARN}🤷 No boxes found - nothing to watch.${C_RESET}"
    echo -e "${C_INFO}   Run ${C_RESET}${C_HIGH}make mon-check${C_RESET}${C_INFO} to see what this machine can reach.${C_RESET}\n"
    exit 0
fi

# 2. Windows, in minutes, from config. Rendered widest-last so the eye reads
#    "now -> trend" left to right.
read -r -a WINDOWS <<< "$MON_BOARD_WINDOWS"

# Minutes -> a short human label (5 -> 5m, 60 -> 1h, 1440 -> 24h).
function win_label() {
    local m=$1
    if   [ "$m" -ge 1440 ]; then echo "$((m / 1440))d"
    elif [ "$m" -ge 60 ];   then echo "$((m / 60))h"
    else                         echo "${m}m"
    fi
}

# 3. Sparkline. Bucketing happens HERE, not on the box - glyphs are a rendering
#    concern and the box has no business knowing about them.
SPARK_CHARS=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)

function sparkline() {
    local values=($1) out="" min max range idx
    [ ${#values[@]} -eq 0 ] && { printf '%s' ""; return; }

    min=$(printf '%s\n' "${values[@]}" | sort -g | head -1)
    max=$(printf '%s\n' "${values[@]}" | sort -g | tail -1)
    range=$(awk -v a="$max" -v b="$min" 'BEGIN{print a-b}')

    for v in "${values[@]}"; do
        # A flat series has no range; render it mid-scale rather than dividing
        # by zero or bottoming out, which would read as "idle" for a pegged CPU.
        if awk -v r="$range" 'BEGIN{exit !(r <= 0)}'; then
            idx=3
        else
            idx=$(awk -v v="$v" -v m="$min" -v r="$range" 'BEGIN{printf "%d", (v-m)/r*7}')
        fi
        out+="${SPARK_CHARS[$idx]}"
    done
    printf '%s' "$out"
}

# 4. Ask ONE box for everything the board needs, in one SSH round trip.
#    Emits a flat, parseable protocol rather than pre-formatted text, so the
#    renderer owns layout entirely:
#       BOX <cpu_now> <mem_now> <disk_now> <load_now> <cpu_w1> ...
#       SPARK_BOX <values...>
#       APP <name> <state> <code> <ms_now> <cpu> <mem> <restarts> <down_ratio> <ms_w1> ...
#       SPARK_APP <name> <values...>
function fetch_box() {
    local host=$1
    {
        cat ./lib-board.sh
        cat << REMOTE
COLLECT_DIR="${MON_COLLECT_DIR}"
WINDOWS="${WINDOWS[*]}"
REMOTE
        cat << 'REMOTE'

if ! has_collector; then
    echo "NOCOLLECTOR"
    exit 0
fi

BOX_TSV="${COLLECT_DIR}/box.tsv"
APPS_TSV="${COLLECT_DIR}/apps.tsv"

# box.tsv: ts(1) cpu(2) mem(3) disk(4) load(5)
LINE="BOX"
LINE="$LINE $(tsv_last "$BOX_TSV" 2) $(tsv_last "$BOX_TSV" 3) $(tsv_last "$BOX_TSV" 4) $(tsv_last "$BOX_TSV" 5)"
for w in $WINDOWS; do
    LINE="$LINE $(tsv_avg "$BOX_TSV" 2 "$w") $(tsv_avg "$BOX_TSV" 3 "$w")"
done
echo "$LINE"
echo "SPARK_BOX $(tsv_series "$BOX_TSV" 2 40)"

# apps.tsv: ts(1) app(2) state(3) code(4) ms(5) cpu(6) mem(7) restarts(8) uptime(9)
for app in $(app_names); do
    L="APP $app $(tsv_last "$APPS_TSV" 3 "$app") $(tsv_last "$APPS_TSV" 4 "$app")"
    L="$L $(tsv_last "$APPS_TSV" 5 "$app") $(tsv_last "$APPS_TSV" 6 "$app")"
    L="$L $(tsv_last "$APPS_TSV" 7 "$app") $(tsv_last "$APPS_TSV" 8 "$app")"
    L="$L $(app_down_ratio "$app" 60)"
    for w in $WINDOWS; do
        L="$L $(tsv_avg "$APPS_TSV" 5 "$w" "$app")"
    done
    echo "$L"
    echo "SPARK_APP $app $(tsv_series "$APPS_TSV" 5 40 "$app")"
done
REMOTE
    } | ssh -q -o BatchMode=yes -o ConnectTimeout=8 "$host" 'bash -s' 2>/dev/null
}

# 5. Colour a percentage against the same thresholds vps-stats uses, so the two
#    boards agree about what "bad" looks like.
function pct_color() {
    local v=$1
    [ "$v" = "-" ] && { printf '%s' "$C_INFO"; return; }
    if   awk -v v="$v" 'BEGIN{exit !(v >= 90)}'; then printf '%s' "$C_ERROR"
    elif awk -v v="$v" 'BEGIN{exit !(v >= 70)}'; then printf '%s' "$C_WARN"
    else                                              printf '%s' "$C_SUCCESS"
    fi
}

# 6. Render everything once. Returns 1 if any app is down, so --once can be a
#    CI gate exactly like mon-apps-once.
function draw_board() {
    local any_down=0 tmp
    tmp=$(mktemp -d -t iacarus-board.XXXXXX)

    # Fan out: one background SSH per box, results to per-box files. A slow or
    # dead host costs its own ConnectTimeout, never everyone else's.
    local host
    for host in "${BOXES[@]}"; do
        fetch_box "$host" > "${tmp}/${host}" 2>/dev/null &
    done
    wait

    echo -e "${C_HIGH}📊 IaCarus - FLEET BOARD${C_RESET} ${C_INFO}(${CONTEXT}; windows: $(for w in "${WINDOWS[@]}"; do printf '%s ' "$(win_label "$w")"; done))${C_RESET}"

    for host in "${BOXES[@]}"; do
        local out; out=$(cat "${tmp}/${host}" 2>/dev/null)
        echo ""

        if [ -z "$out" ]; then
            echo -e "  ${C_ERROR}✗ ${host}${C_RESET} ${C_INFO}- unreachable (no SSH)${C_RESET}"
            continue
        fi

        if [ "$out" = "NOCOLLECTOR" ]; then
            echo -e "  ${C_WARN}⚠ ${host}${C_RESET} ${C_INFO}- no collector installed${C_RESET}"
            echo -e "    ${C_INFO}run ${C_RESET}${C_HIGH}cd hetzner && make vps-collect-enable${C_RESET}"
            continue
        fi

        # --- box row ---
        local b; b=$(grep '^BOX ' <<< "$out")
        local cpu mem disk load
        cpu=$(awk '{print $2}' <<< "$b"); mem=$(awk '{print $3}' <<< "$b")
        disk=$(awk '{print $4}' <<< "$b"); load=$(awk '{print $5}' <<< "$b")

        printf "  %b%-20s%b  cpu %b%5s%%%b  mem %b%5s%%%b  disk %b%5s%%%b  load %s\n" \
            "$C_HIGH" "$host" "$C_RESET" \
            "$(pct_color "$cpu")" "$cpu" "$C_RESET" \
            "$(pct_color "$mem")" "$mem" "$C_RESET" \
            "$(pct_color "$disk")" "$disk" "$C_RESET" \
            "$load"

        if [ "$WATCH" -eq 1 ]; then
            local sb; sb=$(sed -n 's/^SPARK_BOX //p' <<< "$out")
            [ -n "$sb" ] && echo -e "    ${C_INFO}cpu $(sparkline "$sb")${C_RESET}"
        else
            # windowed averages: cpu/mem pairs, one per window
            local i=6 w out_line="    "
            for w in "${WINDOWS[@]}"; do
                out_line+="$(win_label "$w") cpu $(awk -v i="$i" '{print $i}' <<< "$b")% mem $(awk -v i="$((i+1))" '{print $i}' <<< "$b")%   "
                i=$((i + 2))
            done
            echo -e "${C_INFO}${out_line}${C_RESET}"
        fi

        # --- app rows ---
        local appline
        while IFS= read -r appline; do
            [ -z "$appline" ] && continue
            local name state code ms acpu amem restarts ratio
            name=$(awk '{print $2}' <<< "$appline");  state=$(awk '{print $3}' <<< "$appline")
            code=$(awk '{print $4}' <<< "$appline");  ms=$(awk '{print $5}' <<< "$appline")
            acpu=$(awk '{print $6}' <<< "$appline");  amem=$(awk '{print $7}' <<< "$appline")
            restarts=$(awk '{print $8}' <<< "$appline"); ratio=$(awk '{print $9}' <<< "$appline")

            local dot="${C_SUCCESS}●${C_RESET}"
            if [ "$state" != "up" ]; then
                dot="${C_ERROR}●${C_RESET}"
                any_down=1
            fi

            printf "    %b %-14s %-4s %6sms  cpu %5s%%  mem %6sMB  ↻%-3s  down %s\n" \
                "$dot" "$name" "$code" "$ms" "$acpu" "$amem" "$restarts" "$ratio"

            if [ "$WATCH" -eq 1 ]; then
                local sa; sa=$(sed -n "s/^SPARK_APP ${name} //p" <<< "$out")
                [ -n "$sa" ] && echo -e "      ${C_INFO}ms $(sparkline "$sa")${C_RESET}"
            else
                # Windowed latency. Fields 10.. are one average per window, in
                # the order MON_BOARD_WINDOWS declares them - this is the trend
                # that turns a snapshot into a time series, and the whole reason
                # the samples are stored rather than probed live.
                local j=10 lat="      "
                for w in "${WINDOWS[@]}"; do
                    lat+="$(win_label "$w") $(awk -v i="$j" '{print $i}' <<< "$appline")ms   "
                    j=$((j + 1))
                done
                echo -e "${C_INFO}${lat}${C_RESET}"
            fi
        done <<< "$(grep '^APP ' <<< "$out")"
    done

    rm -rf "$tmp"
    echo ""
    echo -e "${C_INFO}● up  ● down   ↻ restarts   'down' = down-samples/total in the last hour${C_RESET}"

    return "$any_down"
}

# 7. One-shot (default and --once) or live.
if [ "$WATCH" -eq 0 ]; then
    # Called in a CONDITION, not bare: draw_board returns 1 for a red board,
    # and a bare non-zero return trips utils.sh's global ERR trap, printing the
    # "Script aborted!" panic block over a perfectly legitimate result. Same
    # guard mon-apps.sh documents at its own --once path.
    if draw_board; then RC=0; else RC=1; fi

    # --once is the CI form: a down app must fail the step. The interactive
    # default stays quiet about exit codes but computes the same value, so the
    # two can never disagree about what "down" means.
    [ "$ONCE" -eq 1 ] && exit "$RC"
    exit 0
fi

# Live: home the cursor and clear to end of screen rather than `clear` - no
# flicker, and scrollback survives. Cursor hidden for the duration, restored by
# the trap so a Ctrl-C mid-refresh never leaves an invisible cursor behind.
function board_cleanup() {
    tput cnorm 2>/dev/null
    echo ""
    exit 0
}
trap board_cleanup INT TERM

tput civis 2>/dev/null
clear

while true; do
    tput cup 0 0 2>/dev/null
    # Condition-guarded for the same reason as the one-shot path: a red board
    # must not fire the ERR trap and shred the redraw with a panic block.
    if draw_board; then :; else :; fi
    tput ed 2>/dev/null
    echo -e "${C_INFO}   refreshing every ${INTERVAL}s - Ctrl-C to stop${C_RESET}"
    sleep "$INTERVAL"
done
