# 🦅 IaCarus - BACKLOG

Planning ledger for upcoming work. Nothing here is built yet - this file
registers **what** we want and **why**, plus the decisions already made so we
don't relitigate them at implementation time.

Style anchors (every story must match these):

- Per-domain `Makefile` targets, `## help` annotated, `.PHONY` kept in sync.
- `#!/bin/bash` scripts that `source ../config.sh` + `../utils.sh`.
- Numbered step comments, emoji status lines, `$C_*` colors, idempotent + rollback.
- Remote work via `ssh -q -t "$HOST" 'bash -s' <<'EOF'` heredocs, host chosen
  with `select_server_interactive`, guarded by `check_ssh_access`.
- Reference implementations to copy from: `hetzner/vps-health-check.sh`,
  `hetzner/vps-rails-app-add.sh`, `cloudflare/r2-provision.sh`, `utils.sh`.

Legend: 🔴 not started · 🟡 in progress · 🟢 done

---

## 🧭 North Star (SPRINT B architecture)

**Monitoring data lives on the app boxes; the "MON box" is a stateless viewer.**

The sar history (SPRINT A) sits on each app box. App health endpoints live on
each app box. So the monitoring/observability box holds **no state** - it is a
thin, portable **client** that SSHes into the fleet and renders. Consequence:

> "New Hetzner mon box" and "run from my laptop" are **the same viewer**, just a
> different host. We build the viewer once; where it runs is a runtime choice,
> never a code fork.

Build philosophy: **Hybrid.**

- **Hardware** → a ready-made tool (**Glances** in central/browser mode) because
  a live multi-box metrics TUI is a solved problem and reinventing it in sh would
  be worse and huge.
- **Apps** → **home-grown sh/curl TUI**, because liveness/latency/speed checks
  are trivial, our style wins here, and every ready-made option (gatus,
  uptime-kuma, Netdata…) is a web dashboard - exactly the "Grafana crap" we're
  avoiding.

No web UIs. No time-series database. `ssh mon` (or run local) → nice TUI. Done.

---

## 🅰️ SPRINT A - box self-service (disk, cleanup, health)

### A0 🟢 Infra: add `sysstat` (sar) to the box image

**Why:** `make vps-stats` wants a 1/5/15/**30-min**/**1h** sense of CPU/mem/disk/
net. Load average natively covers only 1/5/15-min and only for CPU-ish load. Real
30-min/1h trends for mem/net/disk need a lightweight historical collector. Chosen
tool: **`sysstat`** (standard Ubuntu package, tiny footprint) - decided, not open.

**Scope (done)**
- Added `sysstat` to `packages:` in `hetzner/vps-user_data.yml.template`.
- Enabled collection in `runcmd` (`/etc/default/sysstat` → `ENABLED="true"`,
  `daemon-reload`, enable the timer, prime one sample) - done in runcmd, not
  write_files, because write_files runs before package install.
- Dense **2-min** sampling via a `sysstat-collect.timer.d/iacarus.conf` drop-in
  (`OnCalendar=*:00/02`) - **resolves the interval open Q**: 10-min was too
  coarse for a 5-min window; 2-min gives ~2-3 points at 5m, ~15 at 30m, ~30 at
  1h. NOTE: on Ubuntu 24.04 sampling is driven by the systemd **timer**, not
  cron - `debian-sa1` self-suppresses under systemd, so a `/etc/cron.d` sampler
  silently no-ops (the original cron attempt was a bug; fixed in v0.6.1).
- **Backfill for existing boxes:** `make vps-stats-enable`
  (`hetzner/vps-stats-enable.sh`) - idempotent install + timer override + prime
  over SSH. Kept separate so `vps-stats` stays strictly read-only.

**Acceptance**
- Fresh box: `sar` returns history within a few minutes of boot.
- Old box: `make vps-stats-enable` makes `vps-stats` fully functional.

---

### A1 🟢 `make vps-doctor` - inspect + guided disk cleanup

**Why:** "some sort of command where I can inspect the machine, and maybe run
some cleanups - logs, docker crap, etc… in terms of disk." The box already ships
`ncdu`, a weekly `docker-prune` cron, and docker log rotation (10m×3); this target
makes that on-demand and visible.

**Scope (done)** - `hetzner/vps-doctor.sh`:
- **Inspect (read-only):** disk usage (`df`), biggest top-level dirs
  (`du -xhd1 /`, minus the root total), journal size (`journalctl
  --disk-usage`), docker reclaimable (`docker system df`), apt cache + count of
  autoremovable packages, installed-kernel count, `/tmp`. One `ssh 'bash -s'`
  heredoc.
- **Guided cleanup (opt-in, default No):** `docker system prune -f`,
  `journalctl --vacuum-time=7d`, `apt-get clean` + `autoremove`, and a
  double-guarded `docker volume prune` (default OFF - can delete app data).
- **Pattern:** prompt LOCALLY, act via discrete `ssh -n` calls (a piped
  `bash -s` heredoc can't read y/N). Prints before/after free space on `/`.

**Acceptance (met)**
- Read-only unless you say yes; every destructive action is opt-in per prompt.
- Prints before/after free space. Verified read-only end-to-end on
  hetzner-vps-2 (surfaced 1.3 GB reclaimable docker images + 263 MB apt cache).

**Decisions (resolved):** separate target (keeps `vps-stats` read-only);
`docker volume prune` is default-OFF behind two explicit confirmations.

---

### A2 🟢 `make vps-stats` - health/monitoring snapshot (1/5/15/30m/1h)

**Why:** "a monitoring sense - cpu, mem, disk, net… 1 min, 5 min, 15 min, 30 min,
1h sense of how healthy the server is." Read-only, safe, run anytime.

**Scope (done)** - `hetzner/vps-stats.sh`, styled on `vps-health-check.sh`:
- **Load 1/5/15:** native from `/proc/loadavg`, coloured against core count.
- **Windows table (now/5m/15m/30m/1h):** CPU busy %, mem used %, disk tps, net
  rx/tx kB/s. History from `sar -s <start>` Average lines; "now" from a 1-sec
  live `sar` sample. Column positions pinned to Ubuntu 24.04 sysstat (12.6),
  extracted by matching the header field name (robust to minor layout drift).
- **Memory + swap** (`free -h`), **disk space** (`df` with per-mount use-%
  colouring), **top processes** by CPU and by MEM.
- Degrades gracefully when sysstat is absent (CPU/disk/net rows show `-` with a
  "run `make vps-stats-enable`" hint; load/mem/disk/top still render).

**Acceptance**
- One screen, glanceable, all windows present when sysstat has data.
- Zero writes to the box (verified: read-only commands only).

**Reuse note (for SPRINT B):** the `sar` window parsers live inline in
`vps-stats.sh` for now. When B2 needs the same reads, factor them into a shared
`hetzner/lib-stats.sh` rather than duplicating. **Don't** copy-paste the parsing.

---

### A3 🟢 Bake R2 CORS into `vps-app-add` (upl bucket)

**Why:** the app-facing **upl** bucket needs browser CORS for direct
PUT/GET uploads. Decision: **bake into `vps-app-add`** (no standalone target) -
CORS applied right after the upl bucket is created.

**Target policy** (parameterized - origin is per-app, not hardcoded):
```json
[
  {
    "AllowedOrigins": ["https://<app-origin>"],
    "AllowedMethods": ["GET", "PUT"],
    "AllowedHeaders": ["*"],
    "ExposeHeaders": ["ETag"],
    "MaxAgeSeconds": 3600
  }
]
```

**Scope**
- New helper in `utils.sh`, e.g. `r2_put_bucket_cors <BUCKET> <ORIGIN>` using
  `aws s3api put-bucket-cors` against `$CF_R2_S3_CLIENT_URL` (mirror the aws-cli
  usage already in `r2-provision.sh`). Build the JSON with `jq -n` (like
  `cloudflare_create_scoped_token`), never string-concat.
- In `hetzner/vps-rails-app-add.sh`, as step 4b (after the buckets exist, BEFORE
  any token is minted so a bad origin aborts with no orphan credentials), prompt
  for the public origin(s) and apply. Idempotent (re-running re-puts the same
  policy). Only the **upl** bucket gets CORS; the bkp bucket never does.
- Surface the applied origin in the final provisioning summary block.

**Acceptance**
- `make vps-app-add` yields an upl bucket with exactly the policy above.
- Re-running the same app doesn't error or duplicate.
- Origin is fully typed at the prompt (comma-separated for multiple).

**Open Q → RESOLVED:** no shared base domain. One box hosts many apps on
unrelated domains (`client-a.com`, `client-b.com.br`, …), so there is no useful
`<base-domain>` to derive a default from - step 4b simply prompts for the full
origin(s) every time. The `CF_APP_BASE_DOMAIN` idea was dropped.

---

### A4 🟢 `vps-stats` - fix the post-midnight `1h` (and wider) window gap

**Why:** the window columns silently showed `-` for roughly the first hour after
the **box's local midnight** (observed ~21:50 BRT = ~00:50 UTC on a UTC box: the
`1h` cell blanked, then filled once the clock passed 01:00 UTC). Root cause was
in `sar_avg()` (`hetzner/vps-stats.sh`): it ran `sar $flags -s "$start"` with no
`-f`, so sar only ever read **today's** day-file (`/var/log/sysstat/sa$(date
+%d)`). When `N minutes ago` crosses local midnight, `$start` (e.g. `23:50:00`)
is later than every timestamp in the post-midnight file → zero rows → empty →
`cell()` printed `-`. Same failure for the 30m/15m/5m cells in the minutes right
after midnight. A day-file-scope limitation of `sar -s`, not bad data.

**Priority note:** fixed **before** the A2 reuse note (lines ~126-128) pulls
these parsers into a shared `hetzner/lib-stats.sh` for B2 - so no SPRINT B
consumer inherits the bug. Landed in `vps-stats.sh` while it still lives in one
place.

**Scope (done)** - `hetzner/vps-stats.sh`:
- New `sar_span()` helper spans the midnight boundary: when `date -d "$1 minutes
  ago" +%d` differs from `date +%d`, it reads **yesterday's** day-file (`-f
  /var/log/sysstat/sa<DD> -s "$start"`) for the pre-midnight tail, then today's
  file for the post-midnight head; otherwise the plain single-file `-s` path.
- `sar_avg()` and `net_win()` now **compute their own count-weighted mean** over
  the numeric data rows (target column matched by header name, per A2's
  drift-robustness) instead of trusting sar's single `Average:` line - which
  structurally can't span two files. A `$1 ~ /^[0-9:]+$/` row guard excludes the
  `Average:`/`RESTART` lines (without it, `net_win` double-counts `Average:`).
- Stays **read-only** (zero writes). Missing/rotated yesterday file → the extra
  sar call errors to `/dev/null` and it degrades to today-only, never failing.

**Acceptance**
- Parsing verified with two-file (crossed-midnight) fixtures: count-weighted mean
  correct across the boundary; same-day path unchanged (no regression); `net_win`
  no longer double-counts the `Average:` row. `bash -n` clean.
- **Live-verify pending:** the true end-to-end proof (real box, `1h` cell
  populated) can only be observed in the ~21:00-22:00 BRT window after UTC
  midnight - do a `make vps-stats` run there to close it out.

**Decision (resolved):** box timezone stays **unmanaged/UTC** (option a) - the
wrap fix is correct regardless of TZ, and the SPRINT B viewer reads each box's
own clock anyway, so per-box TZ isn't assumed uniform. No `vps-user_data.yml`
change. (Option b, pinning box TZ, was dropped.)

---

## 🅱️ SPRINT B - monitoring / observability box

> Read the **North Star** above first. Viewer is stateless + portable; data lives
> on the app boxes; Hybrid build (Glances for HW, home-grown sh for apps).

### B0 🟢 Fleet inventory (shared by every mon target)

**Why:** the viewer needs to know which boxes/apps exist. Avoid a hand-kept list
that drifts.

**Design (decided):** an **in-repo, auto-maintained app registry**. The "vs
litestream labels" Open Q is resolved in favour of an explicit registry, because
only an explicit record carries the **health path** (labels don't) and lets the
app viewer (B4) run from a credential-less laptop with just `curl` (deriving from
box state would need SSH + Hetzner + CF creds every run). The "hand-kept lists
drift" fear is answered by **auto-writing** it from the app add/remove scripts -
it drifts no more than `/etc/litestream.yml`, which those scripts already keep in
sync the same way.

**Scope**
- **Hardware:** no storage - derive boxes from `hcloud server list` (already used
  by `select_server_interactive`) when run locally; read a cached inventory on a
  dedicated mon box that may not hold Hetzner creds.
- **Apps:** a single repo file `mon/registry.json` - a JSON array, one object per
  app: `{ app_slug, box, label, base_url, health_path, name }`, **keyed on
  `app_slug`** (`${PROJECT_CODE}-${APP_LABEL}-${ENVIRONMENT}`, see
  `vps-rails-app-add.sh`). `label` alone is **not** a valid key: uniqueness is
  only ever enforced per-box (app-add greps that one box's
  `/etc/litestream.yml`), so the same label may legally exist on two boxes and
  would collide fleet-wide. `app_slug` is already fleet-unique - it is what the
  R2 buckets and scoped tokens are named after. `box` + `label` are retained as
  fields (removal resolves by them, see below); `project_code` / `environment`
  stay derivable from the slug. **JSON + `jq`** (not YAML):
  `jq` is already a project dependency, and it gives safe, idempotent
  append/remove without a YAML parser or fragile hand-edits.
- **Auto-maintenance:** new `utils.sh` helpers `mon_registry_add` /
  `mon_registry_remove` (mirroring `litestream_register_db` / `_remove_db`),
  called from `vps-rails-app-add.sh` (after successful provisioning) and
  `vps-rails-app-remove.sh`. app-add already has `label`, `box` (`$SELECTED_NAME`)
  and the public origin (`$CORS_ORIGIN`); it additionally prompts for
  `health_path` (default `/up`, the Rails health endpoint) and `name` (default =
  label). `base_url` = the canonical origin (first of `$CORS_ORIGIN` if several).
- **Removal lookup (important):** `vps-rails-app-remove.sh` only ever prompts for
  **box + label** - it derives `APP_SLUG` from the litestream bucket read at
  lines ~79-81, *inside* the `if BKP_BUCKET readable` branch, which is allowed to
  fail non-fatally. So `mon_registry_remove` must **not** depend on that read.
  It resolves the slug **locally out of the registry** by `(box, label)`
  (`jq --arg b --arg l 'map(select(.box==$b and .label==$l))'`) and deletes by the
  `app_slug` it finds. No SSH, no orphaned entry when litestream is unreadable.
  A miss (app predates the registry, backfill not run) warns and continues -
  same non-fatal posture as the existing token-revocation warning.
- **Read path:** a small `mon/` lib fn that emits the app list for B1/B4 to
  iterate (`jq -r`). Keep it the single source of truth - no other target keeps
  its own list.
- **Privacy:** `mon/registry.json` holds client base URLs and this repo is public
  (`gh` → `github.com/FilipusDev/iacarus`). It is therefore **gitignored**, with a
  committed `mon/registry.example.json` carrying fake entries - mirroring the
  existing `.env` / `.env.example` split. The registry is local operator state,
  not source.
- **Backfill:** the registry starts empty; already-provisioned apps aren't in it.
  Provide a one-shot manual `mon-register` (or a documented hand-seed) to add
  existing apps once - small, since the fleet is tiny today.

**Acceptance**
- One source of truth (`mon/registry.json`) for "what to watch"; no duplicate
  lists across targets.
- `make vps-app-add` appends its app; `make vps-app-remove` drops it; re-running
  either is idempotent (no dupes, no error on missing).
- Two apps sharing a `label` on **different boxes** coexist without collision,
  and removing one leaves the other intact.
- `vps-app-remove` still deregisters cleanly when the litestream bucket read
  fails (no orphaned registry entry).
- The live registry is never committed; `mon/registry.example.json` is.

**Delivered**
- `config.sh`: `PROJECT_ROOT` (derived from the existing `.env` probe) +
  `MON_REGISTRY`, so the path resolves identically from root or a domain dir.
- `utils.sh`: `mon_registry_add` (upsert, keyed on slug), `mon_registry_remove`
  (resolves by box+label, prints the slug, rc 1 on miss), `mon_registry_list`
  (read path for B1/B4). Atomic sibling-temp + rename, since `jq` cannot read
  and write one file in a single pass.
- `vps-rails-app-add.sh`: step 4c prompts `health_path` (default `/up`) and
  display `name` alongside the CORS prompt (all input up front); step 10b writes
  the row **non-fatally** - the app is already live by then, so a bookkeeping
  failure warns instead of triggering the token rollback.
- `vps-rails-app-remove.sh`: step 10 drops the row, warning on a miss.
- `.gitignore`: `mon/registry.json` + `mon/registry.json.*` (stray temps).

**Verified** (isolated harness, 19 assertions, all pass): upsert doesn't
duplicate; same label on two boxes coexists and removing one leaves the other;
removal needs no SSH and no bucket read; miss returns 1 twice over (unknown box,
right box + wrong label); list is sorted and empty-safe on a fresh clone; quotes
and `&` in values round-trip as data; no temp files left behind.

**Gotcha for B1/B4:** call `mon_registry_remove` in a condition
(`if SLUG=$(...)`). A bare call trips the global `ERR` trap on the normal miss
path and prints the "Script aborted!" panic block. Documented at the function.

**Backfilled:** the one existing app, `ccg-2026-01-mpl-prd` (`mpl` on
hetzner-vps-2, `https://mpl.filipus.dev.br/up`), added via `mon_registry_add`
itself rather than by hand. Its facts were *derived*, not retyped: `base_url`
from the upl bucket's live CORS policy (`get-bucket-cors`), `box` + `label` from
`/etc/litestream.yml`, and `/up` confirmed answering 200. Removal was then
dry-run against a copy - `(hetzner-vps-2, mpl)` resolves to the right slug.
The registry is therefore no longer empty, and B4 has a real target on day one.

**Not yet verified:** the end-to-end `make vps-app-add` / `vps-app-remove` runs,
which would provision real Cloudflare + Hetzner resources. The helpers are now
proven against both synthetic and real data, but the *call sites inside the two
scripts* (steps 4c/10b and 10) have not executed - that needs one live app cycle.

**Deferred to B1:** the `mon-register` backfill one-shot lands with the `mon/`
Makefile rather than as a bare script with no control plane to hang off.

---

### B1 🟢 `make mon` - the viewer entrypoint (local **or** mon box)

**Why:** single command that opens the TUI, runnable from a laptop or the
dedicated mon box unchanged (North Star).

**Scope**
- New `mon/` domain dir with its own `Makefile` (mirror `hetzner/`, `cloudflare/`)
  and root-Makefile delegation (`make mon`).
- Detect context: if `hcloud` + SSH aliases exist locally, drive the fleet
  directly; if on the dedicated mon box, use its provisioned SSH access.
- Sub-targets: `mon-hw` (B2), `mon-apps` (B4). `make mon` = a small chooser or a
  combined view.

**Acceptance**
- Same repo, same command, works from laptop and from mon box. ✅

**Delivered**
- `mon/` domain dir + `mon/Makefile` (mirrors hetzner/cloudflare), root `make mon`
  delegation, README control-plane block updated.
- `utils.sh`: `mon_context()` → `operator` (hcloud answers, fleet discoverable)
  or `viewer` (registry + ssh config only). Not a code fork - it bounds hardware
  *discovery* (B2); app checks (B4) need neither, only curl + the registry.
- `mon-check` - readiness report: context, tooling, registry, per-box SSH
  reachability. Read-only. Exits 1 on missing tooling.
- `mon-list` - offline registry table. No network, no ssh, no credentials.
- `mon-register` - the B0 backfill, **deriving** rather than asking: `base_url`
  from the upl bucket's live CORS policy, `label` from the box's
  `/etc/litestream.yml` (offered as a menu, so a typo can't orphan the row
  against `vps-app-remove`'s box+label lookup). Every derived value is an
  overridable default; without creds each falls back to a prompt. Verifies the
  health endpoint before writing.
- `config.sh`: `MON_REGISTRY` is now overridable (`${MON_REGISTRY:-...}`) so a
  mon box can point outside the repo and it can be run against a fixture.

**Verified**
- `operator` and `viewer` contexts both exercised (the latter by running with
  `hcloud` hidden from `PATH`): same code, correct detection, and
  `mon-register` produced a byte-identical row in both.
- Degradation: absent registry, empty registry, and missing `jq` all handled -
  the first two are normal states (exit 0, pointed at the fix), the third exits 1.
- `mon-register` round-tripped the real `ccg-2026-01-mpl-prd` against a fixture,
  reproducing the hand-built row exactly. Live registry untouched throughout.

**Bug found + fixed while testing:** `ssh` forwards stdin to the remote command,
so the un-`-n`'d calls ate the answers meant for later prompts. Two sites:
`mon-register`'s label read (aborted outright), and `mon-check`'s reachability
loop - where the loop's stdin *is* the box list, so it would have silently
checked only the first box and skipped the rest. Latent on a one-box fleet.
Both now use `ssh -n`, matching A1's discipline.

---

### B2 🔴 Hardware near-online - Glances central/browser

**Why:** live multi-box CPU/mem/disk/net TUI matching `MON → APP 1/APP 2`,
reusing SPRINT A's on-box data where sensible.

**Scope**
- **On each app box:** install `glances` and run it in **server mode** (data
  stays on the box). Add to `hetzner/vps-user_data.yml.template` (packages +
  a `glances.service`), plus a backfill step for existing boxes (pairs naturally
  with A0's backfill). Bind to localhost and reach it over the SSH tunnel - **do
  not** open a firewall port (the box is zero-ingress by design; keep it that
  way).
- **On the viewer:** `make mon-hw` opens `glances --browser` (or connects to a
  chosen box) **through SSH port-forwards**, so nothing new is exposed publicly.
- Confirm glances server honors our "zero open ports" rule - tunnel only.

**Acceptance**
- `make mon-hw` → one TUI listing every app box, drill into each, live.
- No new inbound firewall rules on any app box.

**Open Q**
- Glances server auth + bind: enforce localhost-only + SSH tunnel (preferred) vs.
  password-protected bind. Default: **localhost + tunnel**.

---

### B3 🔴 Dedicated mon box - cloud-init `mon` profile (optional host)

**Why:** let the stateless viewer live on a cheap always-on Hetzner box, not just
a laptop. Optional - the viewer already runs locally (B1).

**Scope**
- A `mon` variant of the cloud-init template (or a flag on `vps-provision.sh`)
  that installs the viewer deps (glances client, curl/jq, our scripts) and the
  SSH keys/aliases needed to reach app boxes - **outbound SSH only**, still
  zero-ingress.
- Since the box is stateless, it can be destroyed/recreated freely; document that.

**Acceptance**
- `make vps-new` (mon profile) → a box from which `make mon` just works.
- Rebuilding the mon box loses nothing (all data is on the app boxes).

---

### B4 🔴 App observability - home-grown sh/curl TUI

**Why:** "apps observability, liveness, speed, latency" - our style, no web UI.

**Scope**
- Per-app health checks over the fleet inventory (B0): HTTP status, response
  time (curl `-w %{time_total}` breakdown - dns/connect/ttfb/total), TLS expiry,
  optional content/JSON assertion.
- A simple, refreshing TUI (watch-loop or a tidy redraw) in the health-check
  voice: 🟢/🟡/🔴 per app, latency numbers, last-checked. Runs from the viewer,
  reaching apps over their public URL and/or via SSH tunnel for internal ones.
- Reuse SPRINT A metric helpers where an app check also wants box context.

**Acceptance**
- `make mon-apps` → live liveness+latency board for all registered apps.
- Pure sh + curl + jq; no daemon, no database, no web page.

**Open Qs**
- Public URL checks vs. tunnelled internal checks (or both)?
- Alerting later (SPRINT C?) - for now, eyeball the TUI. Out of scope here.

---

## 🧊 Parked - SPRINT C / D sketches (NOT ratified)

> Captured so they stop floating around. **Nothing here is a decision.** These
> are dreams-out-loud plus a third-party prompt sketch, kept only so SPRINT B
> can be built without forgetting where it might lead. Do not treat any of it as
> designed, scoped, or agreed. Re-open properly once B0-B4 are green.

**Origin (verbatim intent):** *"maybe a SPRINT C, where I could have alerts?
maybe reports of the monitoring? and maybe a D SPRINT with a nice 'status' page
for all my boxes' apps."*

### C? Alerting + light reports

- A cron-driven check loop over the B0 registry: non-200 or latency over a
  threshold dispatches a message out (Telegram bot / webhook / email).
- A daily digest ("pulse") summarising 24h of availability into one message.

### D? Public status page

- A cron/CI loop compiles a **static** `status.html` (vanilla HTML/CSS, our
  design tokens) and ships it to a public R2 bucket behind a custom domain.
  Zero compute, cached at the edge, nothing to keep alive.

### ⚠️ Unresolved before either can be scoped

- **Alert state.** A truly stateless loop re-alerts every run for the whole
  outage. Dedup/hysteresis needs *somewhere* to remember "already told you".
  Where does that live, and what suppresses flapping? This is the actual design
  question in C, not a detail.
- **Who runs the loop.** C's cron and D's generator both need an always-on
  host. On a laptop, the status page freezes green at lid-close while a box
  burns. This makes **B3 (mon box) a prerequisite for C/D, not "optional"** -
  contradicting B3's current framing. Resolve before scoping either.
- **Freshness vs. edge cache.** "Un-killable + cached" and "reflects reality"
  pull against each other; someone owns the R2 cache TTL and the staleness
  window that comes with it.
- **No mail pipeline exists.** There is no SES/SMTP path anywhere in this repo
  today. Any email-based C story is building that from zero first.
- **Prompt-mode caveat.** A piped `bash -s` heredoc cannot read `y/N` (A1's
  lesson). Any C script wanting confirmation uses the vps-doctor pattern:
  prompt locally, act via discrete `ssh -n`.

---

## 📌 Decisions locked (do not relitigate)

- Historical stats collector = **`sysstat`/sar**, sampled every **2 min** via a
  `sysstat-collect.timer` drop-in (A0, done; timer not cron - see A0 note).
- CORS delivery = **baked into `vps-app-add`**, upl bucket only, origin(s) typed
  fully at the prompt - no shared base domain (A3, done).
- SPRINT B build = **Hybrid** (Glances for HW, home-grown sh for apps).
- MON viewer = **stateless + portable**; data lives on app boxes; local and
  dedicated-box are the same viewer.
- Zero-ingress is sacred: all mon traffic rides **SSH tunnels**, never new open
  ports.
- App registry (B0) = **`mon/registry.json`**, JSON + `jq`, **auto-maintained**
  by `vps-app-add`/`vps-app-remove`. Not litestream-derived (labels carry no
  health path; deriving needs infra creds every run). Explicit record lets the
  app viewer run from a credential-less laptop with just `curl`.
- Registry key (B0) = **`app_slug`**, not `label` - label is only unique per box
  and collides fleet-wide. Removal resolves the slug locally by `(box, label)`
  via `jq`, never via the litestream bucket read (which may fail).
- Registry file (B0) = **gitignored**, shipped as `mon/registry.example.json`.
  Public repo; the live file holds client base URLs. Operator state, not source.

## ❓ Open questions to resolve before coding

1. ~~B0: app health registry = litestream-label-derived vs. a `mon.d` config
   file.~~ **RESOLVED** → in-repo `mon/registry.json`, auto-maintained (see B0 +
   Decisions locked).
2. B2: glances server bind/auth (localhost+tunnel assumed).
