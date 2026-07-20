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

# Colors only — the doctor reads no secret and no provider setting, so it deliberately does NOT
# source config.sh. It used to, and inherited config.sh's exits: a missing .env or a locked vault
# killed the whole run before the first check printed. `exit` inside a sourced file terminates the
# CALLER rather than failing the `source`, so the fallback that used to sit here could never be
# reached — the doctor died printing nothing at all, which is the worst possible failure mode for
# the one tool whose job is noticing that something is wrong. palette.sh has no such dependencies.
source "${SCRIPT_DIR}/palette.sh"

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
# 5. iacarus's version is restated in prose — every copy must match config.mk
# -----------------------------------------------------------------------------
# config.mk is the single source; README.md and CLAUDE.md restate it for readers. Keeping them in
# sync is a rule nobody remembers mid-bump: a `v0.13.2` sat in CLAUDE.md through three releases.
echo -e "\n${C_HIGH}▶ Version restatement${C_RESET}"
declared="$(sed -nE 's/^VERSION := (v[0-9]+\.[0-9]+\.[0-9]+).*/\1/p' "${SCRIPT_DIR}/config.mk")"
if [ -z "$declared" ]; then
  fail "config.mk declares no VERSION"
else
  # Only the two files iacarus/CLAUDE.md names as the version artifact. A version string anywhere
  # else — a changelog, an ADR, a tag list — is history and must NOT be rewritten to match.
  stale=0
  for f in "${SCRIPT_DIR}/README.md" "${SCRIPT_DIR}/CLAUDE.md"; do
    [ -f "$f" ] || { fail "${f#$ROOT/} missing"; stale=1; continue; }
    while IFS= read -r hit; do
      [ -z "$hit" ] && continue
      found="${hit#*:}"; found="${found//\`/}"
      [ "$found" = "$declared" ] \
        || { fail "${f#$ROOT/}:${hit%%:*} says $found, config.mk says $declared"; stale=1; }
    done <<< "$(grep -noE '`v[0-9]+\.[0-9]+\.[0-9]+`' "$f")"
  done
  [ "$stale" = "0" ] && pass "$declared restated consistently in README.md, CLAUDE.md"
fi

# -----------------------------------------------------------------------------
# 6. setup.sh's DEPS array is restated in prose — every copy must match it
# -----------------------------------------------------------------------------
# setup.sh is what actually checks; the docs only describe. When they disagree, a reader installs
# the wrong set and `make setup` fails on a tool no doc mentioned — which is how `make` and
# `glances` went missing from the root CLAUDE.md list for two releases.
#
# The two restatement sites are named explicitly because they are structurally different: one is a
# parenthesised inline list, the other a numbered section with comma-grouped bold headers. A generic
# extractor would match neither reliably, so each gets its own two-line parser.
echo -e "\n${C_HIGH}▶ Dependency list${C_RESET}"
norm() { tr ',' '\n' | tr -d ' `*' | grep -v '^$' | sort -u; }
declared_deps="$(sed -nE 's/^DEPS=\((.*)\)/\1/p' "${SCRIPT_DIR}/setup.sh" | tr -d '"' | tr ' ' ',' | norm)"
if [ -z "$declared_deps" ]; then
  fail "setup.sh declares no DEPS array"
else
  cmp_deps() { # label, file, extracted list
    local label="$1" file="$2" got="$3"
    if [ -z "$got" ]; then
      fail "$label — no dependency list found in ${file#$ROOT/}"
      return
    fi
    local missing extra
    missing="$(comm -23 <(echo "$declared_deps") <(echo "$got") | paste -sd' ')"
    extra="$(comm -13 <(echo "$declared_deps") <(echo "$got") | paste -sd' ')"
    if [ -z "$missing" ] && [ -z "$extra" ]; then
      pass "$label matches setup.sh ($(echo "$declared_deps" | paste -sd' '))"
    else
      [ -n "$missing" ] && fail "$label omits: $missing"
      [ -n "$extra" ] && fail "$label lists what setup.sh does not check: $extra"
    fi
  }
  # Site 1 — the workspace CLAUDE.md's inline gloss: `make setup   # ... dep check (a, b, c)`
  cmp_deps "CLAUDE.md dep-check gloss" "$ROOT/CLAUDE.md" \
    "$(grep -oE 'dep check \([^)]*\)' "$ROOT/CLAUDE.md" | sed -E 's/dep check \(|\)//g' | norm)"
  # Site 2 — README §Dependencies: numbered entries headed `**tool:**` or `**tool, tool:**`
  cmp_deps "README §Dependencies" "${SCRIPT_DIR}/README.md" \
    "$(sed -nE 's/^[0-9]+\. \*\*([a-z0-9, ]+):\*\*.*/\1/p' "${SCRIPT_DIR}/README.md" | norm)"
fi

# -----------------------------------------------------------------------------
# 7. SCHEMA declares the item's fields; RUNBOOK records them — the two must agree
# -----------------------------------------------------------------------------
# The highest-stakes pairing in the fleet, and the only one whose failure surfaces during a restore:
# a field SCHEMA declares but RUNBOOK never writes is a field nobody records, and you find out on
# the one day there is no time to reconstruct it. Eleven were missing when this was checked by hand.
echo -e "\n${C_HIGH}▶ SCHEMA ↔ RUNBOOK field parity${C_RESET}"
SCHEMA="$ROOT/daedalus/SCHEMA.md"; RUNBOOK="$ROOT/daedalus/RUNBOOK.md"
if [ ! -f "$SCHEMA" ] || [ ! -f "$RUNBOOK" ]; then
  skip "SCHEMA.md or RUNBOOK.md missing — parity check skipped"
else
  # SCHEMA side, two extractions because the file names fields two ways:
  #   1. op:// references — exact, and the only form for r2/edge/rails/bkp. Restricted to <SLUG>
  #      items: op://DevOps/iacarus/... is the control plane's own item, not a per-app field.
  #   2. the `meta` table's first column — meta is recorded, never referenced, so it has no op:// form.
  schema_fields="$( { grep -ohE 'op://DevOps(-Recovery)?/<SLUG>/[a-z_]+/[a-z_]+' "$SCHEMA" \
                        | sed -E 's#.*/([a-z_]+)/([a-z_]+)$#\1.\2#'
                      awk '/^### `meta`/{m=1;next} /^#{2,3} /{m=0} m && /^\|/{print}' "$SCHEMA" \
                        | cut -d'|' -f2 | grep -oE '`[a-z_]+`' | tr -d '`' | sed 's/^/meta./'
                    } | sort -u )"
  # RUNBOOK side: every field it tells you to write, in `section.field[type]=` form.
  runbook_fields="$(grep -ohE '"[a-z_]+\.[a-z_]+\[' "$RUNBOOK" | tr -d '"[' | sort -u)"

  # `smoke.*` is the one deliberate asymmetry: SCHEMA documents it to say it is FORBIDDEN in a new
  # app (Ephemeral Smoke Rule, ADR-0007 §5), so a RUNBOOK that records it would be the defect.
  unrecorded="$(comm -23 <(echo "$schema_fields") <(echo "$runbook_fields") | grep -v '^smoke\.' | paste -sd' ')"
  undeclared="$(comm -13 <(echo "$schema_fields") <(echo "$runbook_fields") | paste -sd' ')"

  [ -z "$unrecorded" ] \
    && pass "all $(echo "$schema_fields" | grep -vc '^smoke\.') SCHEMA fields are recorded by RUNBOOK" \
    || fail "SCHEMA declares fields RUNBOOK never records: $unrecorded"
  [ -z "$undeclared" ] \
    && pass "RUNBOOK records nothing SCHEMA has not declared" \
    || fail "RUNBOOK records fields SCHEMA never declares: $undeclared"
fi

# -----------------------------------------------------------------------------
# 8. Every `make <target>` a doc names must exist, and where it says to run it
# -----------------------------------------------------------------------------
# Two distinct defects, and the split is what keeps this check quiet enough to trust:
#
#   a. the target exists nowhere in the fleet — a typo (`make vps-check-heath`);
#   b. the doc says `cd X && make y`, but X's Makefile has no `y` — the RUNBOOK told you to run
#      `cd iacarus && make vps-app-add` for months; the target lives in `iacarus/hetzner`.
#
# Prose that names a target WITHOUT a `cd` is deliberately not checked for location: it is making no
# claim about where you are, so there is nothing there to be wrong. That is why this needs no
# opt-out comment — the noisy case was never a defect to begin with.
echo -e "\n${C_HIGH}▶ Make targets${C_RESET}"
declare -A target_dirs=()
while IFS= read -r mk; do
  # A partial checkout finds no Makefile at all; without this the loop hands sed an empty filename
  # and every documented target is then reported as undefined — a wall of failures describing the
  # checkout rather than the docs.
  [ -n "$mk" ] || continue
  d="$(dirname "$mk")"
  while IFS= read -r t; do
    [ -n "$t" ] && target_dirs["$t"]+="$d "
  done <<< "$(sed -nE 's/^([a-z][a-z0-9_-]*):.*/\1/p' "$mk")"
done <<< "$( { find "$ROOT" -name Makefile -not -path '*/.git/*'
               [ -n "$(mpl_dir)" ] && find "$(mpl_dir)" -maxdepth 1 -name Makefile; } 2>/dev/null )"

unknown=0; misplaced=0; checked=0
if [ "${#target_dirs[@]}" = "0" ]; then
  skip "no Makefile found — target check skipped"
else
while IFS= read -r hit; do
  [ -z "$hit" ] && continue
  file="${hit%%:*}"; rest="${hit#*:}"; line="${rest%%:*}"; text="${rest#*:}"
  tgt="$(sed -E 's/.*\bmake ([a-z][a-z0-9_-]*).*/\1/' <<< "$text")"
  # `make mon-box-*` and `make <target>` document a shape rather than naming one target.
  grep -qE "\bmake ${tgt}[*<]" <<< "$text" && continue
  if [ -z "${target_dirs[$tgt]+x}" ]; then
    # A target named inside a prohibition is the doc doing its job — `make smoke-setup` appears
    # only to forbid it. Same ALLOW window section 2 uses, for the same reason.
    lo=$(( line > WINDOW ? line - WINDOW : 1 ))
    sed -n "${lo},$(( line + WINDOW ))p" "$file" 2>/dev/null | grep -qE "$ALLOW" && continue
    fail "${file#$ROOT/}:$line — no Makefile defines 'make $tgt'"; unknown=1; continue
  fi
  checked=$((checked + 1))

  # Only same-line `cd X && … make y` makes a location claim. A `cd` three paragraphs up does not,
  # and guessing that it does is how this class of check turns into noise.
  grep -qE 'cd [^ ]+ &&.*\bmake '"$tgt"'\b' <<< "$text" || continue
  said="$(sed -E 's/.*cd ([^ ]+) &&.*/\1/' <<< "$text")"
  # Resolve as the reader would: relative to the doc, to its repo, then to the workspace.
  docdir="$(dirname "$file")"
  for base in "$docdir" "$docdir/.." "$ROOT"; do
    [ -f "$base/$said/Makefile" ] && { resolved="$(cd "$base/$said" && pwd)"; break; }
    resolved=""
  done
  if [ -z "$resolved" ]; then
    fail "${file#$ROOT/}:$line — 'cd $said' resolves to no directory with a Makefile"; misplaced=1
  elif ! grep -q " $resolved " <<< " ${target_dirs[$tgt]}"; then
    homes="$(sed "s|$ROOT/||g; s|$HOME/|~/|g" <<< "${target_dirs[$tgt]% }")"
    fail "${file#$ROOT/}:$line — 'make $tgt' is not in $said; it lives in $homes"; misplaced=1
  fi
done <<< "$(md_files | xargs grep -nE '\bmake [a-z][a-z0-9_-]*' 2>/dev/null)"

[ "$unknown" = "0" ] && pass "every 'make <target>' named in the docs exists ($checked references)"
[ "$misplaced" = "0" ] && pass "every 'cd X && make y' names the directory that defines y"
fi

# -----------------------------------------------------------------------------
# 9. Pinned versions — reminders only, never fatal
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

      # Verify the registry against reality. A registry that can drift from the files it describes
      # is the very failure this tool exists to catch — without this, bumping LITESTREAM_VERSION in
      # config.sh and forgetting the TSV leaves the doctor confidently reporting the old value.
      drift=""
      if [ "$where" != "-" ]; then
        # "mpl/..." rows live outside the workspace root; resolve them through mpl_dir.
        wfile="$ROOT/$where"
        case "$where" in mpl/*) wfile="$(mpl_dir)/${where#mpl/}" ;; esac
        if [ ! -f "$wfile" ]; then
          drift="${C_ERROR}(where: $where not found)${C_RESET}"
        elif ! grep -qF "$pinned" "$wfile" 2>/dev/null; then
          actual="$(grep -ohE '\bv?[0-9]+\.[0-9]+(\.[0-9]+)?\b' "$wfile" 2>/dev/null | head -1)"
          drift="${C_ERROR}(REGISTRY DRIFT: file says ${actual:-?}, registry says $pinned)${C_RESET}"
        fi
      fi

      shown="$where"; [ "$where" = "-" ] && shown="(nothing pins it locally)"
      line=$(printf "%-14s %-10s %-34s reviewed %sd ago" "$tool" "$pinned" "$shown" "$age")

      if [ -n "$drift" ]; then
        # Registry drift is a real defect, not a reminder — it makes the doctor itself untrustworthy.
        fail "$line  $drift"
      elif [ "$age" -ge "$STALE_DAYS" ]; then
        warn "$line  ${C_WARN}→ review${C_RESET}"
      else
        pass "$line"
      fi
      # Best-effort upstream check. Offline, rate-limited, or missing jq simply skips.
      if [ "$upstream" != "-" ] && command -v jq >/dev/null 2>&1; then
        latest=$(curl -fsS --max-time 4 "https://api.github.com/repos/${upstream}/releases/latest" 2>/dev/null \
                 | jq -r '.tag_name // empty' 2>/dev/null)
        # Repos that tag without cutting Releases (kamal-proxy) 404 above; newest tag is close enough
        # for a reminder.
        [ -z "$latest" ] && latest=$(curl -fsS --max-time 4 "https://api.github.com/repos/${upstream}/tags?per_page=1" 2>/dev/null \
                 | jq -r '.[0].name // empty' 2>/dev/null)
        [ -n "$latest" ] && [ "$latest" != "$pinned" ] \
          && skip "  ${tool} upstream: ${latest} available ($([ "$pinned" = floating ] && echo unpinned || echo "pinned ${pinned}"))"
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
