#!/bin/bash

# =============================================================================
# 📊 REMOTE TSV REDUCERS - shared by the board readers
#
# ⚠️  THIS FILE IS NEVER SOURCED LOCALLY. Every function here runs ON THE BOX,
# so the file is CONCATENATED ONTO THE FRONT OF THE ssh HEREDOC and executed by
# the remote `bash -s` - the same idiom hetzner/lib-stats.sh already uses:
#
#     { cat ./lib-board.sh; cat << 'EOF'
#     ... remote body calling box_windows / app_windows ...
#     EOF
#     } | ssh -q "$HOST" 'bash -s'
#
# Consequences that matter when editing:
#   - NO local variables from config.sh/utils.sh exist here ($C_* included).
#     Define what you need, or take it as an argument.
#   - Pure bash + coreutils + awk that a hardened Ubuntu 24.04 box has.
#
# WHY REDUCE ON THE BOX: a week of 30-second samples is ~20k lines per file.
# Shipping that over SSH to compute an average would move megabytes per box per
# refresh. These emit a handful of lines instead.
# =============================================================================

COLLECT_DIR="${COLLECT_DIR:-/var/log/iacarus}"

# Does this box collect at all? Callers render a hint instead of empty rows.
#
# A FUNCTION, not a variable computed at load time: this file is concatenated
# AHEAD of the caller's body, which is where COLLECT_DIR gets its real value.
# Evaluating eagerly would test the default path and then be wrong for every
# box whose collector lives anywhere else - and wrong in the quiet direction,
# reporting "no collector" for a box that is collecting fine.
has_collector() {
    [ -s "${COLLECT_DIR}/box.tsv" ]
}

# Average a numeric column over the last N minutes.
#
# '-' is the collector's marker for "not measurable this tick" (first sample
# after boot, container gone mid-deploy). Those rows are SKIPPED rather than
# counted as zero - averaging a zero in would quietly drag every window down and
# make a healthy box look better or worse than it is.
#
# Emits '-' when the window holds no usable sample, so the reader never has to
# distinguish "no data" from "genuinely zero".
tsv_avg() {  # $1=file  $2=column index  $3=minutes  [$4=app filter for apps.tsv]
    local file=$1 col=$2 mins=$3 app=${4:-}
    [ -s "$file" ] || { printf '%s' "-"; return; }

    awk -F'\t' -v col="$col" -v cutoff="$(( $(date +%s) - mins * 60 ))" -v app="$app" '
        $1 >= cutoff {
            if (app != "" && $2 != app) next
            v = $col
            if (v == "-" || v == "") next
            sum += v; n++
        }
        END { if (n > 0) printf "%.1f", sum / n; else printf "-" }
    ' "$file"
}

# Most recent value of a column - "right now", as distinct from an average.
tsv_last() {  # $1=file  $2=column index  [$3=app filter]
    local file=$1 col=$2 app=${3:-}
    [ -s "$file" ] || { printf '%s' "-"; return; }

    awk -F'\t' -v col="$col" -v app="$app" '
        {
            if (app != "" && $2 != app) next
            v = $col
            if (v == "-" || v == "") next
            last = v
        }
        END { if (last != "") printf "%s", last; else printf "-" }
    ' "$file"
}

# Every app that has appeared in the retained window, newest first by last seen.
# Read from the DATA, not from kamal-proxy: an app that died an hour ago must
# still appear on the board, and asking the proxy would silently drop it at
# exactly the moment you want to see it.
app_names() {
    [ -s "${COLLECT_DIR}/apps.tsv" ] || return 0
    awk -F'\t' '{ last[$2] = $1 } END { for (a in last) printf "%s\t%s\n", last[a], a }' \
        "${COLLECT_DIR}/apps.tsv" | sort -rn | awk '{print $2}'
}

# Count of down samples vs total in a window - the honest liveness number. An
# app that flaps reads as "17/120 down", which a single up/down snapshot at
# refresh time would hide completely.
app_down_ratio() {  # $1=app  $2=minutes
    [ -s "${COLLECT_DIR}/apps.tsv" ] || { printf '%s' "-"; return; }
    awk -F'\t' -v app="$1" -v cutoff="$(( $(date +%s) - $2 * 60 ))" '
        $1 >= cutoff && $2 == app {
            n++
            if ($3 != "up") d++
        }
        END { if (n > 0) printf "%d/%d", d + 0, n; else printf "-" }
    ' "${COLLECT_DIR}/apps.tsv"
}

# Last N values of a column, space separated - raw material for a sparkline.
# Rendered by the VIEWER, because the box has no business knowing about glyphs.
tsv_series() {  # $1=file  $2=column  $3=count  [$4=app filter]
    local file=$1 col=$2 count=$3 app=${4:-}
    [ -s "$file" ] || return 0
    awk -F'\t' -v col="$col" -v app="$app" '
        { if (app != "" && $2 != app) next; v = $col; if (v == "-" || v == "") v = 0; print v }
    ' "$file" | tail -n "$count" | tr '\n' ' '
}
