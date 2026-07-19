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
# 📡 MON - live hardware board across the fleet (SPRINT B2)
#
# Each app box runs a glances server bound to 127.0.0.1 (see
# hetzner/vps-glances-enable.sh). This opens ONE SSH TUNNEL PER BOX onto a
# distinct local port, writes a throwaway glances.conf naming those ports, and
# hands it to glances' browser mode - so one TUI lists the whole fleet and you
# drill into any box, live.
#
# ZERO-INGRESS BY CONSTRUCTION: no box exposes 61209, no firewall rule is added,
# and the tunnels die with this script. SSH is the only authenticator.
#
# NOT set -e: an unreachable box must degrade to "that one is skipped", never
# abort the board. Every fallible call is guarded so the ERR trap stays quiet.
#
# Usage: make mon-hw
# =============================================================================

# 1. glances drives the UI here, so its absence is fatal - but it is a VIEWER
#    dependency, not a box one, and installing software on the operator's
#    machine is not this script's business. Say what to run and stop.
if ! command -v glances > /dev/null 2>&1; then
    echo -e "\n${C_ERROR}❌ glances is not installed on this machine.${C_RESET}"
    echo -e "${C_INFO}   The viewer needs it; the boxes already have it.${C_RESET}"
    echo -e "${C_INFO}   Arch:   ${C_RESET}${C_HIGH}sudo pacman -S glances${C_RESET}"
    echo -e "${C_INFO}   Ubuntu: ${C_RESET}${C_HIGH}sudo apt install glances${C_RESET}"
    echo ""
    exit 1
fi

# 1b. glances' browser mode is a CURSES app, so it needs a real terminal. Caught
#     the hard way: over a non-interactive 'ssh host make mon-hw' (no -t), TERM
#     arrives empty and curses dies mid-initscr, dumping a Python traceback over
#     what is really just "you didn't ask for a terminal". Say that instead -
#     and say it BEFORE spending time opening tunnels we'd only tear down.
if [ -z "$TERM" ] || [ "$TERM" = "dumb" ] || [ "$TERM" = "unknown" ]; then
    echo -e "\n${C_ERROR}❌ No usable terminal (TERM='${TERM}').${C_RESET}"
    echo -e "${C_INFO}   The hardware board is a full-screen curses UI - it needs a TTY.${C_RESET}"
    echo -e "${C_INFO}   Over SSH, ask for one explicitly:${C_RESET}"
    echo -e "   ${C_HIGH}ssh -t <mon-box> \"cd ${MON_REMOTE_PATH:-/opt/iacarus}/mon && make mon-hw\"${C_RESET}"
    echo ""
    exit 1
fi

# 2. Which boxes? This is the one place the execution context genuinely changes
#    behaviour (see mon_context in utils.sh):
#      operator -> ask Hetzner, so boxes with no registered app are still shown
#      viewer   -> the registry is all we have; it only knows boxes running apps
#    Either way the NAME must match an ssh config alias - vps-provision.sh writes
#    the alias using the Hetzner server name, so the two agree by construction.
CONTEXT=$(mon_context)

echo -e "\n${C_INFO}📡 Building the hardware board...${C_RESET}"

if [ "$CONTEXT" = "operator" ]; then
    mapfile -t BOXES < <(hcloud server list -o noheader -o columns=name 2>/dev/null | awk 'NF {print $1}' | sort -u)
    echo -e "   ${C_INFO}context: operator - fleet read live from Hetzner${C_RESET}"
else
    mapfile -t BOXES < <(mon_registry_list | jq -r '.box' 2>/dev/null | sort -u)
    echo -e "   ${C_INFO}context: viewer - fleet read from the registry${C_RESET}"
fi

# 2b. Include THIS host if it serves glances and nothing above already listed it.
#     On a mon box the registry only knows boxes that run APPS, so the viewer
#     host itself would never appear - yet it is the one machine whose health
#     you cannot check from anywhere else, and the thing you most want to see
#     when the board looks wrong. Costs nothing: it is already listening on
#     loopback, so this adds a row, not a connection.
SELF_HOST=$(hostname)

if ! printf '%s\n' "${BOXES[@]}" | grep -qxF "$SELF_HOST"; then
    if (exec 3<>"/dev/tcp/127.0.0.1/${MON_GLANCES_PORT}") 2>/dev/null; then
        exec 3<&-
        BOXES+=("$SELF_HOST")
    fi
fi

if [ ${#BOXES[@]} -eq 0 ]; then
    echo -e "\n${C_WARN}🤷 No boxes found - nothing to watch.${C_RESET}"
    echo -e "${C_INFO}   Run ${C_RESET}${C_HIGH}make mon-check${C_RESET}${C_INFO} to see what this machine can reach.${C_RESET}\n"
    exit 0
fi

# 3. Everything below is disposable: the tunnels and the generated config exist
#    only for this run. Registering the cleanup BEFORE opening anything means a
#    Ctrl-C midway through setup still tears down whatever already came up -
#    otherwise a half-built board would leak ssh processes holding local ports,
#    and the next run would silently allocate different ones.
WORK_DIR=$(mktemp -d -t iacarus-mon-hw.XXXXXX)
GLANCES_CONF="${WORK_DIR}/glances.conf"
TUNNEL_PIDS=()

function cleanup() {
    local pid
    for pid in "${TUNNEL_PIDS[@]}"; do
        kill "$pid" 2>/dev/null
    done
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

# 4. Is a local TCP port already answering? Used both to skip ports in use and
#    to wait for a tunnel to come up. Bash's /dev/tcp needs no extra tooling
#    (nc is not guaranteed on every viewer).
function port_answers() {
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && exec 3<&- && return 0
    return 1
}

# 5. Open one tunnel per box.
#
#    -N (no command) + backgrounded with '&' rather than ssh's own -f: -f makes
#    ssh fork itself, so $! would be a pid that has already exited and we could
#    never kill the real tunnel. Backgrounding the foreground process keeps the
#    pid we hold honest.
#    -o ExitOnForwardFailure=yes: if the forward can't be established, ssh must
#    fail instead of sitting there as a connected session with no tunnel - which
#    would present as an empty box in the TUI rather than an error here.
#    -o BatchMode=yes: a box needing a passphrase fails fast instead of hanging
#    the whole board on an invisible prompt behind the redraw.
echo ""
LOCAL_PORT=$MON_GLANCES_LOCAL_PORT_BASE
SERVER_IDX=0

for BOX in "${BOXES[@]}"; do
    # THIS box, if the viewer happens to be running on one of them (the mon box
    # of B3 monitors itself). Its glances server is already on 127.0.0.1 here,
    # so tunnelling would mean SSHing to ourselves - which needs an ssh alias
    # for our own hostname that nothing creates. Use the local port directly.
    if [ "$BOX" = "$SELF_HOST" ]; then
        if port_answers "$MON_GLANCES_PORT"; then
            SERVER_IDX=$((SERVER_IDX + 1))
            [ "$SERVER_IDX" -eq 1 ] && echo "[serverlist]" > "$GLANCES_CONF"
            {
                echo "server_${SERVER_IDX}_name=localhost"
                echo "server_${SERVER_IDX}_alias=${BOX} (this host)"
                echo "server_${SERVER_IDX}_port=${MON_GLANCES_PORT}"
            } >> "$GLANCES_CONF"
            echo -e "   ${C_SUCCESS}✅ ${BOX}${C_RESET} ${C_INFO}-> 127.0.0.1:${MON_GLANCES_PORT} (local - no tunnel needed)${C_RESET}"
        else
            echo -e "   ${C_WARN}⚠️  ${BOX} skipped${C_RESET} ${C_INFO}(this host runs no glances server)${C_RESET}"
        fi
        continue
    fi

    # Find a free local port for this box.
    while port_answers "$LOCAL_PORT"; do
        LOCAL_PORT=$((LOCAL_PORT + 1))
    done

    ssh -N -o ExitOnForwardFailure=yes \
           -o BatchMode=yes \
           -o ConnectTimeout=8 \
           -L "${LOCAL_PORT}:127.0.0.1:${MON_GLANCES_PORT}" "$BOX" > /dev/null 2>&1 &
    PID=$!

    # Wait for the forward to actually carry traffic. A tunnel that is "up"
    # because ssh hasn't died yet is not the same as one that answers.
    READY=0
    for _ in $(seq 1 "$MON_TUNNEL_TIMEOUT"); do
        if ! kill -0 "$PID" 2>/dev/null; then
            break                      # ssh gave up - box unreachable
        fi
        if port_answers "$LOCAL_PORT"; then
            READY=1
            break
        fi
        sleep 1
    done

    if [ "$READY" -eq 1 ]; then
        TUNNEL_PIDS+=("$PID")
        SERVER_IDX=$((SERVER_IDX + 1))

        # First server also creates the section header.
        if [ "$SERVER_IDX" -eq 1 ]; then
            echo "[serverlist]" > "$GLANCES_CONF"
        fi

        # Every box is 'localhost' as far as glances is concerned - the port is
        # what distinguishes them. The alias is what you actually read in the
        # TUI, so it carries the real box name.
        {
            echo "server_${SERVER_IDX}_name=localhost"
            echo "server_${SERVER_IDX}_alias=${BOX}"
            echo "server_${SERVER_IDX}_port=${LOCAL_PORT}"
        } >> "$GLANCES_CONF"

        echo -e "   ${C_SUCCESS}✅ ${BOX}${C_RESET} ${C_INFO}-> 127.0.0.1:${LOCAL_PORT} (tunnelled)${C_RESET}"
        LOCAL_PORT=$((LOCAL_PORT + 1))
    else
        # Not fatal: a box that is down or has no glances server is exactly the
        # case a monitoring tool exists to survive. Drop it and keep going.
        kill "$PID" 2>/dev/null
        echo -e "   ${C_WARN}⚠️  ${BOX} skipped${C_RESET} ${C_INFO}(no SSH, or no glances server - run 'make vps-glances-enable')${C_RESET}"
    fi
done

# 6. Nothing came up - say so plainly rather than opening an empty browser.
if [ "$SERVER_IDX" -eq 0 ]; then
    echo -e "\n${C_ERROR}❌ No box could be reached - nothing to display.${C_RESET}"
    echo -e "${C_INFO}   Check 'make mon-check', then 'make vps-glances-enable' on the box.${C_RESET}\n"
    exit 1
fi

# 7. Hand over to glances. --browser reads the [serverlist] we just wrote and
#    presents the fleet; ENTER drills into a box, ESC comes back, q quits.
#    On exit the trap kills every tunnel, so the box stops being reachable the
#    moment you close the board.
echo ""
echo -e "${C_HIGH}📡 IaCarus - HARDWARE BOARD${C_RESET} ${C_INFO}(${SERVER_IDX} box(es) - ENTER to drill in, q to quit)${C_RESET}"
sleep 1

# Guarded: glances exiting non-zero (a resize race, a mid-session disconnect,
# or just an unusual quit path) is not an IaCarus failure, and letting it reach
# the global ERR trap would print the "Script aborted!" panic block over a
# perfectly normal exit.
glances --browser --config "$GLANCES_CONF" || true

echo ""
echo -e "${C_INFO}👋 Board closed - all tunnels torn down.${C_RESET}"
echo ""
