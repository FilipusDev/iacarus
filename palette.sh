#!/bin/bash
#
# palette — the fleet's terminal colors, and nothing else.
#
# Split out of config.sh because the two answer different questions. config.sh resolves an
# operator's configuration: it needs .env, it may call `op inject`, and it exits when either is
# unavailable. Colors need none of that, yet anything wanting them used to inherit all of it —
# which is how `make doctor` came to depend on an unlocked 1Password vault to print a checkmark.
#
# Source this directly when you need the palette but not the configuration. config.sh sources it
# too, so every script that already sources config.sh keeps working unchanged.
#
# Kept in sync by hand with config.mk's copy, which cannot source a shell file. That duplication is
# deliberate and documented at both ends.

C_ERROR='\e[1;31m'      # Bold Red (Critical)
C_SUCCESS='\e[1;32m'    # Bold Green (Success)
C_WARN='\e[1;38;5;226m' # Bold Yellow
C_INFO='\e[38;5;39m'    # Blue
C_HIGH='\e[38;5;171m'   # Turquoise
C_RESET='\e[0m'
