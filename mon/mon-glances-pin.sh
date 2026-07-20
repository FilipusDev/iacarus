#!/bin/bash

# Same sourcing guard as mon-hw.sh: run from anywhere but mon/ and these paths
# resolve outside the repo and fail silently, leaving the script with no config.
if ! source ../config.sh 2>/dev/null || ! source ../utils.sh 2>/dev/null; then
    echo "❌ Could not load ../config.sh + ../utils.sh."
    echo "   Run this from the mon/ directory, or use the Makefile target."
    exit 1
fi

# =============================================================================
# 📌 MON - pin this VIEWER's glances to the fleet's version
#
# glances refuses to talk across a major version boundary: its client compares
# 'server_version.split(".")[0]' against its own and aborts the login. The
# browser renders that refusal as a bare OFFLINE row - identical to a dead box -
# which is why 'make mon-hw' guards against it explicitly.
#
# The BOXES are fine on apt: Ubuntu 24.04 ships exactly GLANCES_VERSION, frozen
# for the life of the LTS. A rolling-release viewer is the end that drifts, and
# it drifts silently. This builds a venv holding the pinned build, which
# mon-hw.sh then prefers over whatever the system package manager installed.
#
# The system glances is left completely alone - this adds a build, it does not
# replace one.
#
# Usage: make mon-glances-pin
# =============================================================================

echo -e "\n${C_INFO}📌 Pinning this viewer's glances to ${C_RESET}${C_HIGH}${GLANCES_VERSION}${C_RESET}${C_INFO}...${C_RESET}"

# 1. python3 + venv are the only prerequisites. Check before doing anything, so
#    a missing module is a sentence rather than a traceback halfway through.
if ! command -v python3 > /dev/null 2>&1; then
    echo -e "\n${C_ERROR}❌ python3 is not installed - cannot build the pinned venv.${C_RESET}\n"
    exit 1
fi

if ! python3 -c 'import venv' > /dev/null 2>&1; then
    echo -e "\n${C_ERROR}❌ python3 is present but the 'venv' module is missing.${C_RESET}"
    echo -e "${C_INFO}   Arch:   ${C_RESET}${C_HIGH}sudo pacman -S python${C_RESET}"
    echo -e "${C_INFO}   Ubuntu: ${C_RESET}${C_HIGH}sudo apt install python3-venv${C_RESET}\n"
    exit 1
fi

GLANCES_BIN="${MON_GLANCES_VENV}/bin/glances"

# 2. Already pinned? The venv path carries the version, so an existing binary
#    here is BY CONSTRUCTION the right build - but verify rather than trust the
#    path, since a half-finished venv from an interrupted run would also match.
if [ -x "$GLANCES_BIN" ]; then
    FOUND=$("$GLANCES_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+[0-9.]*' | head -n 1)

    if [ "$FOUND" = "$GLANCES_VERSION" ]; then
        echo -e "   ${C_SUCCESS}✅ Already pinned${C_RESET} ${C_INFO}- ${MON_GLANCES_VENV}${C_RESET}"
        echo -e "\n${C_INFO}   'make mon-hw' will use it automatically.${C_RESET}\n"
        exit 0
    fi

    echo -e "   ${C_WARN}⚠️  Found ${FOUND:-nothing usable} where ${GLANCES_VERSION} should be - rebuilding.${C_RESET}"
    rm -rf "$MON_GLANCES_VENV"
fi

# 3. Build it. Kept quiet because pip's progress bars are noise here, but any
#    failure prints - an unbuildable venv must not look like a successful pin.
echo -e "   ${C_INFO}Building venv at ${MON_GLANCES_VENV}${C_RESET}"
mkdir -p "$(dirname "$MON_GLANCES_VENV")"

if ! python3 -m venv "$MON_GLANCES_VENV" > /dev/null 2>&1; then
    echo -e "\n${C_ERROR}❌ Could not create the venv at ${MON_GLANCES_VENV}.${C_RESET}\n"
    exit 1
fi

echo -e "   ${C_INFO}Installing glances==${GLANCES_VERSION}${C_RESET}"

if ! "${MON_GLANCES_VENV}/bin/pip" install --quiet "glances==${GLANCES_VERSION}"; then
    echo -e "\n${C_ERROR}❌ pip could not install glances==${GLANCES_VERSION}.${C_RESET}"
    # A broken venv left on disk would be picked up by the check in step 2 next
    # run and reported as a version mismatch, which describes the wrong problem.
    rm -rf "$MON_GLANCES_VENV"
    exit 1
fi

# 4. Verify what we actually built, rather than trusting that pip did as asked.
FOUND=$("$GLANCES_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+[0-9.]*' | head -n 1)

if [ "$FOUND" != "$GLANCES_VERSION" ]; then
    echo -e "\n${C_ERROR}❌ Installed ${FOUND:-nothing}, expected ${GLANCES_VERSION}.${C_RESET}\n"
    rm -rf "$MON_GLANCES_VENV"
    exit 1
fi

echo ""
echo -e "   ${C_SUCCESS}✅ Pinned glances ${GLANCES_VERSION}${C_RESET} ${C_INFO}at ${MON_GLANCES_VENV}${C_RESET}"
echo -e "\n${C_INFO}   'make mon-hw' prefers it automatically - your system glances is untouched.${C_RESET}\n"
