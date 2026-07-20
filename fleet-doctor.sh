#!/usr/bin/env bash
#
# fleet-doctor — checks the invariants that span all four repos, and reminds you about pinned
# versions. Read-only: it never edits a file, never touches a box, never calls a provider API.
#
# It exists because every documentation drift found so far shared one shape: a doc restated a fact
# that lived somewhere else, and nothing noticed when the two diverged. Those are all mechanically
# checkable, so they are checked here rather than left to memory.
#
#   make doctor            invariants + version reminders
#   make doctor CHECK=1    invariants only (no network, CI-friendly)
#
# Exit 0 when every invariant holds. Exit 1 when any fails. Version reminders never affect the exit
# code — a stale pin is information, not a broken fleet.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh" >/dev/null 2>&1 || {
  C_ERROR='\e[1;31m'; C_SUCCESS='\e[1;32m'; C_WARN='\e[1;38;5;226m'
  C_INFO='\e[38;5;39m'; C_HIGH='\e[38;5;171m'; C_RESET='\e[0m'
}

# The workspace root is iacarus's parent: the dir holding the sibling repos. Every path below is
# relative to it, so the script works regardless of where it is invoked from.
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHECK_ONLY="${CHECK:-0}"

FAILED=0
pass() { echo -e "  ${C_SUCCESS}✓${C_RESET} $1"; }
fail() { echo -e "  ${C_ERROR}✗${C_RESET} $1"; FAILED=1; }
warn() { echo -e "  ${C_WARN}⚠${C_RESET} $1"; }
skip() { echo -e "  ${C_INFO}∅${C_RESET} $1"; }

# Repos are discovered, not assumed: a missing sibling is reported and skipped rather than fatal, so
# this still runs in a partial checkout.
mpl_dir() {
  for d in "$HOME/Projects/digital-concierge/mpl" "$ROOT/mpl"; do
    [ -d "$d" ] && { echo "$d"; return; }
  done
}

md_files() {
  # Every tracked markdown file across the fleet, excluding .git internals.
  { find "$ROOT" -name '*.md' -not -path '*/.git/*' 2>/dev/null
    [ -n "$(mpl_dir)" ] && find "$(mpl_dir)" -maxdepth 2 -name '*.md' -not -path '*/.git/*' 2>/dev/null
  } | sort -u
}

echo -e "\n🩺 ${C_HIGH}fleet-doctor${C_RESET} — ${ROOT}"

# -----------------------------------------------------------------------------
# 1. The common core must be byte-identical everywhere
# -----------------------------------------------------------------------------
echo -e "\n${C_HIGH}▶ Common core${C_RESET}"
core_files=("$ROOT/CLAUDE.md" "$ROOT/iacarus/CLAUDE.md" "$ROOT/daedalus/CLAUDE.md" \
            "$ROOT/_template_rails-app/CLAUDE.md")
[ -n "$(mpl_dir)" ] && core_files+=("$(mpl_dir)/CLAUDE.md")

declare -A seen=()
missing=0
for f in "${core_files[@]}"; do
  [ -f "$f" ] || { fail "missing: ${f#$ROOT/}"; missing=1; continue; }
  h="$(awk '/FLEET-COMMON-CORE v1/,/\/FLEET-COMMON-CORE/' "$f" | sha256sum | cut -c1-12)"
  [ "$h" = "e3b0c44298fc" ] || [ -z "$h" ] && { fail "no core block in ${f#$ROOT/}"; continue; }
  seen["$h"]+="${f#$ROOT/} "
done
if [ "$missing" = "0" ] && [ "${#seen[@]}" = "1" ]; then
  pass "identical in ${#core_files[@]} files (${!seen[*]})"
elif [ "${#seen[@]}" -gt 1 ]; then
  fail "DIVERGED into ${#seen[@]} variants:"
  for h in "${!seen[@]}"; do echo -e "      ${C_WARN}${h}${C_RESET}  ${seen[$h]}"; done
fi

# -----------------------------------------------------------------------------
# 2. Retired concepts must not be taught anywhere
# -----------------------------------------------------------------------------
echo -e "\n${C_HIGH}▶ Retired patterns${C_RESET}"

# Each rule: a label, a regex for the thing that must not be TAUGHT, and a regex for the contexts
# where mentioning it is legitimate (history notes, prohibitions, amendment records).
#
# The allow-check reads a WINDOW around each hit, not the hit line alone. Prose wraps: a prohibition
# routinely puts the banned term on one line and the word "violation" on the next, and a line-based
# filter reports those as failures. Three lines of context is enough for every case seen so far.
WINDOW=3
check_retired() {
  local label="$1" pattern="$2" allow="$3" real=""
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    # Split declarations: under `set -u`, a multi-assignment `local` expands later RHS values
    # before the earlier names are declared, so `line=${rest%%:*}` would read an unset `rest`.
    local file; file="${hit%%:*}"
    local rest; rest="${hit#*:}"
    local line; line="${rest%%:*}"
    local lo; lo=$(( line > WINDOW ? line - WINDOW : 1 ))
    local hi; hi=$(( line + WINDOW ))
    # Legitimate if the surrounding prose marks it as history, prohibition, or negation.
    sed -n "${lo},${hi}p" "$file" 2>/dev/null | grep -qE "$allow" || real+="${hit}"$'\n'
  done <<< "$(md_files | xargs grep -nE "$pattern" 2>/dev/null)"

  if [ -z "${real//[[:space:]]/}" ]; then
    pass "$label"
  else
    fail "$label — still taught in:"
    echo "$real" | sed "s|$ROOT/||; s|$HOME/|~/|; s|^|      |" | grep -v '^ *$' | head -8
  fi
}

# Contexts where naming a retired pattern is correct rather than a defect. Kept deliberately broad:
# a false PASS here costs a missed doc drift, but a false FAIL trains you to ignore the doctor.
ALLOW='used to be|was deleted|tripwire|[Aa]mended|superseded|grandfather|legacy|predates|violation|forbid|banned|[Nn]ever reintroduce|no longer|lived in daedalus|had no off-box|[Tt]here is no|is not the pattern|do not copy|must not|cannot|removed|retired|Ephemeral Smoke Rule'
check_retired "daedalus filesystem vault"  'daedalus/vault|_slug-template'                "$ALLOW"
check_retired "stored smoke credentials"   '\.\{\{?APP_LABEL\}?\}?-smoke\.env|smoke-setup' "$ALLOW"
check_retired "chmod-based secret storage" 'chmod (600|700) .*(vault|credential)'          "$ALLOW"

# -----------------------------------------------------------------------------
# 3. Cross-repo facts that must exist
# -----------------------------------------------------------------------------
echo -e "\n${C_HIGH}▶ Required artifacts${C_RESET}"
[ -f "$ROOT/_template_rails-app/VERSION" ] \
  && pass "_template_rails-app/VERSION ($(cat "$ROOT/_template_rails-app/VERSION"))" \
  || fail "_template_rails-app/VERSION missing (its CLAUDE.md mandates it)"
for f in daedalus/SCHEMA.md daedalus/RUNBOOK.md; do
  [ -f "$ROOT/$f" ] && pass "$f" || fail "$f missing"
done

# -----------------------------------------------------------------------------
# 4. Every op:// reference in a tracked file must resolve
# -----------------------------------------------------------------------------
echo -e "\n${C_HIGH}▶ 1Password references${C_RESET}"
if ! command -v op >/dev/null 2>&1; then
  skip "op not installed — reference check skipped"
else
  # Only concrete references: anything with a {{PLACEHOLDER}} or <SLUG> is documentation of a shape,
  # not a live pointer, so resolving it would be meaningless.
  refs="$( { md_files; echo "$(mpl_dir)/.kamal/secrets"; } \
           | xargs grep -ohE 'op://[A-Za-z0-9_-]+/[A-Za-z0-9_.+-]+/[A-Za-z0-9_/-]+' 2>/dev/null \
           | grep -vE '\{\{|<|SLUG|APP_LABEL' | sort -u )"
  if [ -z "$refs" ]; then
    skip "no concrete op:// references found"
  else
    while IFS= read -r ref; do
      [ -z "$ref" ] && continue
      if op read "$ref" >/dev/null 2>&1; then
        pass "$ref"
      else
        fail "$ref does not resolve"
      fi
    done <<< "$refs"
  fi
fi

# -----------------------------------------------------------------------------
# 5. Pinned versions — reminders only, never fatal
# -----------------------------------------------------------------------------
if [ "$CHECK_ONLY" != "1" ]; then
  echo -e "\n${C_HIGH}▶ Pinned versions${C_RESET}  ${C_INFO}(reminders — never affect exit code)${C_RESET}"
  REG="${SCRIPT_DIR}/fleet-versions.tsv"
  STALE_DAYS="${STALE_DAYS:-90}"
  if [ ! -f "$REG" ]; then
    skip "fleet-versions.tsv missing"
  else
    now=$(date -u +%s)
    while IFS=$'\t' read -r tool pinned where upstream reviewed; do
      case "$tool" in ''|\#*) continue ;; esac
      age=$(( (now - $(date -u -d "$reviewed" +%s 2>/dev/null || echo "$now")) / 86400 ))
      line=$(printf "%-13s %-10s %-38s reviewed %sd ago" "$tool" "$pinned" "$where" "$age")
      if [ "$age" -ge "$STALE_DAYS" ]; then
        warn "$line  ${C_WARN}→ review${C_RESET}"
      else
        pass "$line"
      fi
      # Best-effort upstream check. Offline, rate-limited, or missing jq simply skips.
      if [ "$upstream" != "-" ] && command -v jq >/dev/null 2>&1; then
        latest=$(curl -fsS --max-time 4 "https://api.github.com/repos/${upstream}/releases/latest" 2>/dev/null \
                 | jq -r '.tag_name // empty' 2>/dev/null)
        [ -n "$latest" ] && [ "$latest" != "$pinned" ] \
          && skip "  ${tool} upstream: ${latest} available (pinned ${pinned})"
      fi
    done < "$REG"
  fi
fi

echo ""
if [ "$FAILED" = "0" ]; then
  echo -e "${C_SUCCESS}✓ fleet-doctor: all invariants hold${C_RESET}\n"
else
  echo -e "${C_ERROR}✗ fleet-doctor: invariants FAILED${C_RESET} — fix the ✗ lines above\n"
fi
exit "$FAILED"
