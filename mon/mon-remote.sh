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
# 📡 MON - run a mon target ON THE MON BOX from here (SPRINT B3, daily driver)
#
# Wraps the "ssh -t <box> 'cd /opt/iacarus/mon && make <target>'" dance so the
# always-on viewer is one make target away instead of a memorized incantation.
#
# The box name is RESOLVED, never hardcoded: destroying and recreating the mon
# box changes its IP and SSH port but keeps its alias, and a second mon box
# should not require editing a Makefile.
#
# NOT set -e: the whole point is to hand back the REMOTE command's exit code
# (mon-apps-once returns non-zero when an app is down, and that must survive the
# trip home for cron/CI to be able to read it).
#
# Usage: ./mon-remote.sh <make-target> [--no-tty]
#        make mon-box-hw / mon-box-apps / mon-box-apps-once
# =============================================================================

TARGET="$1"
TTY_FLAG="-t"

if [ -z "$TARGET" ]; then
    echo -e "${C_ERROR}❌ No target given.${C_RESET}"
    echo -e "${C_INFO}   Usage: ./mon-remote.sh <make-target> [--no-tty]${C_RESET}"
    exit 1
fi

# --no-tty is for the scriptable form. Allocating a pty for a one-shot pass
# would wrap the output in terminal control codes and, worse, make ssh return
# the pty's status rather than a clean pass/fail.
[ "$2" = "--no-tty" ] && TTY_FLAG=""

# 1. Resolve the mon box from the SSH CONFIG, not from Hetzner. This has to work
#    on a machine with no infrastructure credentials (that is the whole viewer
#    premise), and the alias is what 'ssh' will use anyway. MON_BOX overrides
#    for the multi-box or oddly-named case.
if [ -z "$MON_BOX" ]; then
    mapfile -t FOUND < <(awk -v p="^${MON_VPS_BASE_NAME}" \
        'tolower($1)=="host" { for (i=2;i<=NF;i++) if ($i ~ p) print $i }' \
        "${SSH_HOME_PATH:-$HOME/.ssh}/config" 2>/dev/null | sort -u)

    if [ ${#FOUND[@]} -eq 0 ]; then
        echo -e "\n${C_ERROR}❌ No mon box found in your ssh config.${C_RESET}"
        echo -e "${C_INFO}   Looked for a Host starting '${MON_VPS_BASE_NAME}'.${C_RESET}"
        echo -e "${C_INFO}   Create one with: ${C_RESET}${C_HIGH}cd ../hetzner && make vps-new-mon${C_RESET}"
        echo -e "${C_INFO}   Or point at an existing box: ${C_RESET}${C_HIGH}MON_BOX=<alias> make mon-box-apps${C_RESET}"
        echo ""
        exit 1
    elif [ ${#FOUND[@]} -eq 1 ]; then
        MON_BOX="${FOUND[0]}"
    else
        echo "Select the mon box:"
        PS3="Enter number (or 'q' to quit): "
        select ITEM in "${FOUND[@]}"; do
            [[ "$REPLY" == "q" ]] && echo "Aborted." && exit 0
            [ -n "$ITEM" ] && MON_BOX="$ITEM" && break
            echo "Invalid selection."
        done
    fi
fi

# 2. Already ON the mon box? Then this wrapper is a no-op that would SSH to
#    itself - which needs an alias for our own hostname that nothing creates.
#    Run the target directly instead, so the same command works from anywhere.
if [ "$(hostname)" = "$MON_BOX" ]; then
    # '|| RC=$?' rather than a bare call: a non-zero result is MEANINGFUL here
    # (mon-apps-once reports down apps that way), and a bare failing command
    # would trip utils.sh's global ERR trap and print the "Script aborted!"
    # panic block over a board that is simply reporting bad news correctly.
    RC=0
    make "$TARGET" || RC=$?
    exit $RC
fi

# 3. Hand over, and hand the exit code back. 'cd || exit' matters: without it a
#    missing path would run make in the home directory and fail confusingly,
#    instead of saying the viewer was never shipped.
#    '|| RC=$?' for the same reason as the local branch above: a remote board
#    reporting a down app must come back as an exit code, not as a panic block.
RC=0
# shellcheck disable=SC2086
ssh -q $TTY_FLAG "$MON_BOX" "cd '${MON_REMOTE_PATH}/mon' 2>/dev/null || { echo 'Viewer not found at ${MON_REMOTE_PATH} - run: cd hetzner && make vps-mon-setup'; exit 1; }; make $TARGET" || RC=$?

# 255 is ssh's own "connection failed" code - distinguish it from the target
# genuinely reporting a problem, which is what the exit code is FOR.
if [ $RC -eq 255 ]; then
    echo -e "\n${C_ERROR}❌ Could not reach ${MON_BOX}.${C_RESET}"
    echo -e "${C_INFO}   Check 'ssh ${MON_BOX}' works, or run the board locally: ${C_RESET}${C_HIGH}make ${TARGET}${C_RESET}"
    echo ""
fi

exit $RC
