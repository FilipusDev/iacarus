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
- **Live-verified ✅** - `make vps-stats` run at ~21:30 BRT (~00:30 UTC), inside
  the window where the `1h` cell used to blank, rendered correctly. The
  cross-midnight day-file span works against a real box, not just fixtures.
  SPRINT A is fully closed.

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

### B2 🟢 Hardware near-online - Glances central/browser

**Why:** live multi-box CPU/mem/disk/net TUI matching `MON → APP 1/APP 2`,
reusing SPRINT A's on-box data where sensible.

**Scope (done)**
- **On each app box:** `glances` added to `packages:` in
  `hetzner/vps-user_data.yml.template`, plus a
  `glances.service.d/iacarus.conf` drop-in and `systemctl enable --now glances`
  in `runcmd`. Backfill for existing boxes: `make vps-glances-enable`
  (`hetzner/vps-glances-enable.sh`), idempotent, mirroring `vps-stats-enable`.
- **On the viewer:** `make mon-hw` (`mon/mon-hw.sh`) - one SSH tunnel per box
  onto a distinct local port, a generated throwaway `glances.conf`
  `[serverlist]`, then `glances --browser`. Tunnels are torn down on exit by a
  trap registered *before* the first one opens.
- **No firewall change on any box.** Verified externally: `nc` to
  `<public-ip>:61209` is refused on both the app box and the mon box.

**Acceptance (met)**
- `make mon-hw` → one TUI, `2 Glances servers available`, both `ONLINE`, live
  LOAD/CPU%/MEM% updating across redraws, `ENTER` drills into a box.
- No new inbound firewall rules; `ufw` still allows only the randomized SSH port.

**Discovery that changed the shape (worth keeping):** Ubuntu 24.04's `glances`
package **already ships `glances.service` enabled, running
`glances -s -B 127.0.0.1`** - our decided posture, for free. We did NOT lean on
that: glances' own documented default bind is `0.0.0.0`, so the loopback bind is
**restated in a drop-in we own**. Inheriting a packaging default would make
zero-ingress a property of Ubuntu's packaging decisions rather than of ours, and
an upgrade could silently move the server onto the public interface.

**Open Q → RESOLVED (the mechanical one):** N boxes map onto N distinct local
ports by starting at `MON_GLANCES_LOCAL_PORT_BASE` (61209) and incrementing past
any port already answering locally. The remote port is always 61209 - nothing
outside the box ever sees it. The `glances.conf` server list is generated per
run into a temp dir and deleted with the tunnels; **every entry is
`localhost`**, distinguished by port, with the box name carried in
`server_N_alias` so the TUI still reads correctly.

**Note - the viewer host is a box too:** `mon-hw` adds the machine it runs on to
the board when that machine serves glances, reaching it **directly on 127.0.0.1
with no tunnel** (SSHing to yourself would need an alias for your own hostname
that nothing creates). Without this the mon box - the one host whose health you
cannot check from anywhere else - would never appear on its own board.

**Bug caught by live testing (fixed):** `glances --browser` is a curses UI, so a
non-interactive `ssh host make mon-hw` (no `-t`) arrives with `TERM` empty and
dies inside `curses.initscr()`, dumping a Python traceback. `mon-hw` now checks
`TERM` **before opening any tunnel** and prints the `ssh -t` form instead. The
`glances` call is also `|| true`-guarded so an unusual quit path can't reach the
global ERR trap and print "Script aborted!" over a normal exit.

---

### B3 🟢 Dedicated mon box - cloud-init `mon` profile (optional host)

**Why:** let the stateless viewer live on a cheap always-on Hetzner box, not just
a laptop. Optional - the viewer already runs locally (B1).

**Scope (done)**
- **`hetzner/vps-mon-user_data.yml.template`** - a second cloud-init template
  (not conditionals in the app one: cloud-init YAML has no conditionals and
  sed-branching a single template would be fragile). Same hardening controls,
  byte for byte: SSH lockdown, `ufw` default-deny, fail2ban,
  unattended-upgrades. Drops docker/buildx and litestream (no workloads, no
  database). Adds the viewer's tooling: glances, curl, jq, make, git, sysstat.
  Runs the glances **server** too, so the watcher is itself watchable.
- **`--profile app|mon` on `vps-provision.sh`** (`make vps-new-mon`). Only the
  template and the name prefix (`MON_VPS_BASE_NAME`, default `hetzner-mon-`)
  differ; port randomization, ssh config and keyscan stay shared so the two
  profiles cannot drift on the parts that govern access. Numbering is per
  prefix, so adding a mon box never shifts app box names. Boxes are labelled
  `profile=<app|mon>` in Hetzner.
- **`hetzner/vps-mon-setup.sh`** (`make vps-mon-setup`) - ships the operator
  state that must never ride in user-data, and is idempotent.

**Acceptance (met)** - verified on a real box, `hetzner-mon-1` (hel1, cx23):
- `make vps-new-mon` → hardened box, glances active on 127.0.0.1, no docker,
  `ufw` allowing only the randomized SSH port.
- `make vps-mon-setup` → `make mon-check` **from the box** reports
  `Context: viewer`, tooling present, 1 app registered, `hetzner-vps-2`
  reachable.
- `make mon-apps` from the box: app healthy, 173ms total (vs ~250ms from Brazil
  - see the threshold note below).
- `make mon-hw` from the box: both boxes ONLINE in one TUI.
- Rebuilding loses nothing (all data is on the app boxes).

**Decision (locked): the mon box is CREDENTIAL-LESS.** Its generated `.env`
carries `MON_*` tuning only - no Hetzner token, no Cloudflare keys. Reasoning:
- It is the designed "viewer" context from B1. `mon_context` reports `viewer`,
  so hardware targets come from the registry and apps are checked over public
  URLs - exactly the credential-free path B0 was shaped around.
- A stolen mon box then grants **no infrastructure access at all**. Putting a
  Hetzner token on an always-on box to save a `hcloud` call would trade the
  whole point of the design for a convenience.
- **Known consequence, accepted:** a box with **no registered app** is invisible
  from the mon box (it has no way to enumerate the fleet). It remains visible
  from the laptop, which can ask Hetzner. The mon box always adds itself.

**Decision (locked): the mon box GENERATES ITS OWN SSH KEY.** `vps-mon-setup`
runs `ssh-keygen` *on the box*, carries only the **public** half back, and
appends it to each app box's `authorized_keys`. The laptop's private key is
never copied. Reasoning: user-data is retained by Hetzner and served by the
metadata service, so it can never carry a key; and a disposable host should not
hold a credential whose blast radius is the entire fleet. Revocation is dropping
one line from each app box. The key is passphrase-less because the viewer must
run unattended - bounded instead by being separately revocable.

**Note - thresholds are a property of the observer:** the same healthy app
measures ~250ms from Brazil and ~173ms from Helsinki. `vps-mon-setup` therefore
writes **tighter** defaults into the mon box's `.env` (300/1000 ms) than the
laptop's (1200/3000 ms). Do not copy one machine's numbers to another.

**Note - the mon box holds a copy, not a checkout:** `vps-mon-setup` tars the
viewer over SSH (`.git` and `.env` excluded by construction, not by cleanup).
Re-run it after changing `mon/`, `config.sh`, `utils.sh`, or the registry. It
rewrites the box's ssh config **in full**, so a destroyed-and-recreated app box
leaves no stale entry.

---

### B4 🟢 App observability - home-grown sh/curl TUI

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
- `make mon-apps` → live liveness+latency board for all registered apps. ✅
- Pure sh + curl + jq; no daemon, no database, no web page. ✅

**Delivered** - `mon/mon-apps.sh`, targets `mon-apps` (live) + `mon-apps-once`:
- Per-app row: HTTP code, per-phase timing (DNS / CONN / TLS / TTFB / TOTAL, in
  ms) and TLS days-to-expiry, verdict 🟢/🟡/🔴 on TOTAL against
  `MON_LATENCY_WARN_MS` / `MON_LATENCY_CRIT_MS` (both `.env`-overridable, as are
  `MON_REFRESH_SECONDS`, `MON_HTTP_TIMEOUT`, `MON_TLS_WARN_DAYS`).
- curl reports *cumulative* timings; the board converts them to per-phase
  deltas, guarding the TLS phase so plain-http apps render 0 rather than a
  negative.
- **TLS expiry is read once per run**, not per redraw: certificates don't change
  between refreshes and probing costs a second full handshake per app. `openssl`
  is optional - absent, the column reads `-`.
- Redraw homes the cursor + clears to end of screen instead of `clear` (no
  flicker, scrollback survives); cursor is hidden during the loop and restored
  by an INT/TERM trap.
- `--once` is the scriptable form and **exits non-zero when anything is 🔴** -
  the natural thing for a SPRINT C alerting cron to call.
- Deliberately not `set -e`: a failing curl is the signal, not an abort.

**Verified** against a local fixture server producing real failures: plain-http
(no TLS phase, `-` cert), 200-but-slow → 🟡, 200-but-very-slow → 🔴, 404, 500,
connection-refused → `---`, and curl timeout → all render rather than blanking
the board. Exit codes correct in every case; threshold overrides honoured; live
loop redraws on interval and restores the cursor on Ctrl-C.

**Bug found + fixed while testing:** `--once` first decided its exit code by
grepping the rendered board for 🔴 - which always matched, because the legend
line under the table contains a literal 🔴. Every healthy board reported
failure. Now `draw_board` returns a real status from its own counters.

**KNOWN TRADEOFF (documented in-script):** checks are sequential, so a pass
costs the SUM of all response times - worst case `MON_HTTP_TIMEOUT` x (down
apps), which can outlast the refresh interval. Observed: a 6-app fixture with a
3s app managed one pass per 5s. Fine at current fleet size; the fix when it
isn't is background jobs + `wait`, not a daemon.

**Resolved Open Q:** public URL checks only, for now. The registry's `base_url`
is the public origin, checks need no credentials, and that is what keeps the
board runnable from anywhere. Tunnelled internal checks stay unbuilt until
something actually needs them.

**Status glyph = ANSI-coloured `●`, not 🟢/🟡/🔴.** Emoji carry their own palette
from whichever font wins the fontconfig match, and Font Awesome (monochrome,
installed system-wide) beat Noto Color Emoji for U+1F7E2/E1/E4 - rendering every
state as the same grey blob, i.e. a status column conveying nothing. Emoji are
also double-width, so the column's width depended on font fallback. `●` takes
the terminal's own colours and is single-width. Prose emoji elsewhere stay.

**Alignment bug (fixed):** the header used `%7s` while data cells were `%6s` +
`"ms"` = 8 chars, drifting one column per field, cumulatively. Separately,
colouring *inside* a printf format string skews everything after it, because
printf counts ANSI escapes as visible characters. Fields are now padded to width
first and coloured second; the separator is derived from the same arithmetic.
Verified every rendered row is byte-identical in width.

**False all-clear (fixed):** run from anywhere but `mon/`, `source ../config.sh`
resolved outside the repo and failed *silently* - the ERR trap lives in
`utils.sh`, which hadn't loaded either - so the board printed "🤷 No apps
registered - nothing to watch" and exited **0**. A monitoring tool reporting a
clean board because it couldn't find its own config is the worst failure mode
available. All four `mon/` scripts now guard the source and exit 1. NOTE the
same latent pattern exists in `hetzner/` and `cloudflare/` scripts.

**Latency baseline (measured, not guessed):** `/up` answers in **3-6ms on the
box**; from a laptop in Brazil it reads ~250ms steady with reconnect outliers
near 580ms. Handshake numbers (DNS 2ms, connect ~11ms, TLS ~17ms) show TLS
terminating at a Cloudflare edge near São Paulo, so the ~220ms TTFB is the
edge→Helsinki origin round trip, not Rails. Samples are **bimodal** (~220ms vs
~550ms, nothing between = one extra round trip) and the box shows no such split,
placing the variance entirely in the CF↔origin tunnel path. The app is not slow;
the planet is wide. Defaults raised to WARN 1200 / CRIT 3000 to sit above that
noise, and `.env.example` now documents all `MON_*` knobs.

**Design consequence for B3/SPRINT C:** these thresholds describe *the observer*,
not the app. The same fleet reads ~250ms from Brazil and would read ~10ms from a
European mon box - so whichever host ends up doing the alerting cannot inherit
another host's numbers. If mon boxes and laptops ever both alert, thresholds
belong per-viewer (or per-app in the registry), not as one global pair.

---

## 🅲 SPRINT C - one board: box + app time series, on the box

**Why:** SPRINT B2 bet on glances for hardware. That bet failed twice in one
sitting: the viewer could not talk to the boxes at all (glances refuses a MAJOR
version mismatch, and renders the refusal as a bare `OFFLINE` row), and once
pinned to matching versions the *server* returned
`AttributeError: 'dict' object has no attribute 'is_enabled'` from
`getAllPlugins`. The cause is upstream and structural: `stats.py` declares
`self._plugins = collections.defaultdict(dict)`, so a plugin that never loads
becomes an empty `{}` rather than an error, and the plugin list then calls
`.is_enabled()` on a dict. That is a bug in a Python dependency we do not
control, inside a fleet that otherwise runs on bash + coreutils.

The replacement is smaller than it sounds. `vps-stats` already reads real
hardware history off the box via `sar`, parsed by `lib-stats.sh` in pure
bash/awk. `mon-apps` already probes app liveness and latency in pure sh + curl.
Neither stores app data, and nothing joins them. **SPRINT C stores the app half
on the box and renders both halves as one board.**

Shape, per the ratified answers below:

```
viewer (laptop OR mon box)  ->  vps-1  ->  app1, app2, app3
                            ->  vps-2  ->  app4
```

The box is the store. The viewer is thin and holds nothing.

### Decisions locked (ratified 2026-07-20, do not relitigate)

| Decision | Choice |
|---|---|
| Collection point | **On the box**, probing via kamal-proxy on loopback |
| Public-path check | **Kept separately** - `mon-apps` still probes the public URL from the viewer |
| Storage | **Append-only TSV + logrotate** - no database, no daemon beyond a timer |
| App metrics | state + HTTP code, latency ms, container CPU% + mem, restarts + uptime |
| Cadence | **30s sample, 7 day retention**, rotated daily + compressed |
| Rendering | **One-shot table by default**, `--watch` for the live sparkline view |
| Multi-box | **All boxes on one screen**, `--box <name>` narrows |
| App discovery | **`kamal-proxy list`** on the box - zero config, auto-appears on deploy |
| glances | **Removed entirely** - no Python anywhere on a box |

> **Why the public check survives.** On-box probing answers *"is the app
> healthy?"*. It cannot answer *"can the world reach it?"* - an app can be
> perfectly green on loopback while DNS, Cloudflare or the tunnel is broken.
> Two signals, two questions; collapsing them would lose the outage we most
> want to catch.

### ⚠️ One decision still open - hardware sampling resolution

`sar` collects every **10 minutes** (Ubuntu's sysstat default), but the app
series samples every **30 seconds**. Rendering both in one table means two
resolutions in adjacent rows, where a 30s app spike sits beside a hardware
number that is a 10-minute average.

**Recommendation: the collector samples hardware itself, on the same 30s tick,
into its own TSV.** CPU from `/proc/stat` deltas, memory from `/proc/meminfo`,
disk from `df` - all pure bash, no new package. `sar`, `vps-stats` and
`vps-stats-enable` stay exactly as they are, serving the longer historical
windows they were built for. One board, one cadence, one story; `vps-stats`
remains the deep-dive.

The alternative - reconfiguring sysstat to sample faster - couples the new board
to a package's cron layout and still cannot reach 30s cleanly. Not recommended,
but it is the call to make before C1 starts.

### C0 🔴 Demolition - remove glances from the fleet

**Scope**
- Delete `mon/mon-hw.sh`, `mon/mon-glances-pin.sh`, `hetzner/vps-glances-enable.sh`.
- Remove the `mon-hw`, `mon-glances-pin` and `mon-box-hw` Make targets.
- Remove the glances block from `vps-user_data.yml.template`.
- Remove `GLANCES_VERSION` + `MON_GLANCES_VENV` from `config.sh`, and
  `MON_GLANCES_PORT` / `MON_GLANCES_LOCAL_PORT_BASE` / `MON_TUNNEL_TIMEOUT` if
  nothing else claims them.
- Drop the `glances` row from `fleet-versions.tsv` and the dependency bullet
  from `README.md` + root `CLAUDE.md` (the doctor asserts these two lists match
  `setup.sh` - update all three together or it goes red).
- Stop and disable `glances.service` on every existing box, remove the
  `/etc/systemd/system/glances.service.d/iacarus.conf` drop-in, `apt purge`.
- Mark B2 superseded, pointing here.
- **Rewrite the North Star** at the top of this file. It currently ratifies the
  hybrid bet - "Hardware → a ready-made tool (Glances)… because reinventing it
  in sh would be worse and huge". SPRINT C overturns exactly that clause, and a
  planning ledger whose header contradicts its newest sprint is worse than one
  that is merely out of date. The "no web UIs, no time-series database, monitoring
  data lives on the app boxes" half stands and gets stronger.

**Acceptance**
- `make doctor` green with no glances references anywhere.
- No box has a listener on `61209`; no box has Python installed for our sake.
- `~/.local/share/iacarus/glances-*` removed from the viewer.

> Reverts `v0.19.0` (the viewer pin) and most of B2. Deliberate: the pin was the
> right fix for the wrong dependency.

### C1 🔴 On-box collector - `iacarus-collect`

**Scope**
- `/usr/local/bin/iacarus-collect`, pure bash + coreutils + curl + docker CLI.
- Driven by a **systemd timer** (`OnUnitActiveSec=30s`, `AccuracySec=1s`) with a
  `Type=oneshot` service, so systemd will not start a second run while one is
  still going - the natural guard against a hung probe piling up.
- **Discovery:** parse `kamal-proxy list` for `Service`, `Host`, `Target`.
  New apps appear on deploy; removed apps vanish. No file to keep in sync.
- **App probe:** one curl per app through the proxy on loopback, which exercises
  proxy + app and survives redeploys (the container IP changes every deploy, the
  Host header does not):
  ```
  curl -o /dev/null -s -w '%{http_code} %{time_starttransfer}' \
       -H "Host: <host>" --max-time 5 http://127.0.0.1/<health_path>
  ```
- **Container stats:** ONE `docker stats --no-stream` call for all containers,
  never one per app - it is the most expensive thing in the loop.
- **Restarts + uptime:** `docker inspect --format '{{.RestartCount}} {{.State.StartedAt}}'`.
- **Two files, two fixed schemas** - mixing record shapes in one file is what
  makes a TSV unreadable later:
  ```
  /var/log/iacarus/box.tsv    ts  cpu_pct  mem_pct  disk_pct  load1
  /var/log/iacarus/apps.tsv   ts  app  state  code  ms  cpu_pct  mem_mb  restarts  uptime_s
  ```
- `/etc/logrotate.d/iacarus`: daily, `rotate 7`, `compress`, `missingok`,
  `notifempty`. Plain rotation is safe because each run opens, appends and
  closes - no long-lived descriptor, so no `copytruncate` needed.
- Installed by cloud-init on new boxes, plus a `vps-collect-enable` target as the
  backfill path for existing ones - the same split `vps-stats-enable` already
  uses.

**Acceptance**
- Timer active; both TSVs growing at 30s.
- A stopped app records `state=down`, and the collector still completes.
- An app whose health endpoint hangs is cut off at `--max-time` and does not
  delay the next tick.
- Disk cost measured and recorded here (projection: ~4 MB for 3 apps over 7d).

### C2 🔴 The board - the `mon-board` target (one-shot)

**Scope**
- `mon/mon-board.sh`, one SSH per box, boxes fanned out in parallel with `wait`
  (B4's known tradeoff was sequential probing; do not repeat it).
- **Aggregate on the box, not on the viewer.** The remote payload is an awk
  program that reduces the TSVs to windowed averages and returns a few lines.
  Shipping raw TSVs over SSH would move megabytes to compute an average.
- Same remote-payload pattern `lib-stats.sh` already uses - concatenated ahead
  of the ssh heredoc - so there is one idiom for on-box computation, not two.
- Windows: **5m / 15m / 1h / 24h**, matching `vps-stats` so the two read alike.
- Box selection follows `mon_context` exactly as B1 does: operator asks Hetzner,
  viewer reads the registry.
- Exits **non-zero if any app is down**, like `mon-apps-once`, so SPRINT C
  alerting can call it directly.

**Acceptance**
- `mon-board` prints every box with its apps nested, in one screen.
- `--box <name>` narrows; `--once` is the scriptable form.
- A box that is unreachable is rendered as unreachable and does not abort the
  board - the B2 lesson, kept.

### C3 🔴 `--watch` - live view with sparklines

**Scope**
- Redraw by homing the cursor and clearing to end of screen, never `clear`
  (no flicker, scrollback survives) - `mon-apps.sh` already proved this.
- ASCII sparklines from the last N samples, bucketed into `▁▂▃▄▅▆▇█` in pure
  bash. No curses, no framework, no TUI library.
- Hide the cursor during the loop; restore it from an INT/TERM trap.

**Acceptance**
- `mon-board-watch` refreshes without flicker and restores the terminal on
  Ctrl-C, including after a mid-refresh interrupt.

### C4 🔴 Docs + doctor

**Scope**
- Rewrite `mon/OPERATING.md` around the new board; delete the glances sections.
- `README.md` + root `CLAUDE.md`: drop glances, describe `mon-board`.
- Add `mon-board` to the capability table with its question
  (*"what have these boxes and apps been doing?"*).
- Consider a doctor invariant: every registered app is present in its box's
  `kamal-proxy list`, catching an app that was deployed but never registered.

**Acceptance**
- `make doctor` green, including the make-target and dependency-gloss checks.

### Risks + tradeoffs to carry into C1

- **`docker stats --no-stream` is slow** (~1s+, it samples a window internally).
  One call for all containers keeps the duty cycle near 3% at 30s. If it grows,
  drop container stats to every 4th tick rather than lengthening the whole loop.
- **30s was chosen over 60s deliberately** - it catches short outages, at double
  the write volume. Revisit if a box ever runs many apps.
- **Discovery is coupled to kamal-proxy.** An app not fronted by it is invisible
  to the collector. True of nothing today; it would become a real gap the first
  time a non-Kamal service is deployed, and the fallback is the box-local config
  file rejected above.
- **Two probe paths can disagree** - on-box green while the viewer's public
  check is red. That is the design working, and the board should render that
  distinction obviously rather than reconciling them.

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
- Glances (B2) = **bind `127.0.0.1`, SSH tunnel, no glances password** (B2 Open Q,
  resolved). SSH is the authenticator; a public bind would rest zero-ingress on a
  firewall rule instead of on the process not listening, and would add a second
  credential system to rotate across every box and viewer.
- App registry (B0) = **`mon/registry.json`**, JSON + `jq`, **auto-maintained**
  by `vps-app-add`/`vps-app-remove`. Not litestream-derived (labels carry no
  health path; deriving needs infra creds every run). Explicit record lets the
  app viewer run from a credential-less laptop with just `curl`.
- Registry key (B0) = **`app_slug`**, not `label` - label is only unique per box
  and collides fleet-wide. Removal resolves the slug locally by `(box, label)`
  via `jq`, never via the litestream bucket read (which may fail).
- Registry file (B0) = **gitignored**, shipped as `mon/registry.example.json`.
  Public repo; the live file holds client base URLs. Operator state, not source.
- Glances bind (B2) = restated in **a systemd drop-in we own**, never inherited
  from Ubuntu's packaging. The package happens to bind loopback already; that is
  a packaging default, not a contract, and glances' own default is `0.0.0.0`.
- Port mapping (B2) = remote port always 61209; the viewer allocates one local
  port per box from `MON_GLANCES_LOCAL_PORT_BASE` upward, skipping ports in use.
  Generated `glances.conf` is per-run and disposable; every entry is `localhost`
  distinguished by port, box name carried in `server_N_alias`.
- Viewer self-view (B2) = the host running `mon-hw` joins its own board via
  127.0.0.1 with **no tunnel**, so the mon box is not the one unwatchable host.
- Mon box (B3) = **credential-less**. `MON_*` tuning only, no Hetzner/Cloudflare
  keys. Accepted consequence: app-less boxes are invisible from the mon box
  (still visible from the laptop). A stolen mon box grants nothing.
- Mon box key (B3) = **generated on the box**; only the public half travels, to
  each app box's `authorized_keys`. The laptop key is never copied there - and
  no key may ride in user-data, which Hetzner retains and the metadata service
  serves. Revoke by dropping one line per app box.
- Mon profiles (B3) = a **separate cloud-init template**, not conditionals in
  the app one (cloud-init YAML has no conditionals). Hardening controls are kept
  identical between the two; only workload runtime differs.
- Latency thresholds = **a property of the observer, not the app**. ~250ms from
  Brazil vs ~173ms from Helsinki for the same healthy app, so the mon box ships
  tighter defaults than the laptop. Never copy one machine's numbers to another.

## ❓ Open questions to resolve before coding

1. ~~B0: app health registry = litestream-label-derived vs. a `mon.d` config
   file.~~ **RESOLVED** → in-repo `mon/registry.json`, auto-maintained (see B0 +
   Decisions locked).
2. ~~B2: glances server bind/auth (localhost+tunnel assumed).~~ **RESOLVED** →
   localhost bind + SSH tunnel, no glances password (see B2 + Decisions locked).
   The remaining mechanical half - port mapping and `glances.conf` generation -
   is **also resolved and implemented**; see B2 and Decisions locked.
3. ~~B4: public URL checks vs. tunnelled internal checks.~~ **RESOLVED** →
   public URL only; no credentials needed, so the board runs from anywhere.

**SPRINT B is closed.** B0-B4 are all 🟢 and live-verified against
`hetzner-vps-2` (app box) and `hetzner-mon-1` (mon box). Day-to-day usage is
documented in `mon/OPERATING.md`, not here - this file records *why*, that one
records *how*.
