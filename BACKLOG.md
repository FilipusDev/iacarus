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

### A1 🔴 `make vps-doctor` - inspect + guided disk cleanup

**Why:** "some sort of command where I can inspect the machine, and maybe run
some cleanups - logs, docker crap, etc… in terms of disk." The box already ships
`ncdu`, a weekly `docker-prune` cron, and docker log rotation (10m×3); this target
makes that on-demand and visible.

**Scope** (remote heredoc, styled like `vps-health-check.sh`)
- **Inspect (read-only first):** `df -h`, biggest dirs (`du` top-N under `/var`,
  `/var/lib/docker`, `/home`), journald size (`journalctl --disk-usage`), docker
  reclaimable (`docker system df`), apt cache, old kernels, `/tmp`.
- **Guided cleanup (explicit, never silent):** offer each with a `y/N` prompt -
  `docker system prune -f` (and optionally `--volumes` behind an extra guard),
  `journalctl --vacuum-time=…` / `--vacuum-size=…`, `apt-get clean` +
  `autoremove`, truncate rotated logs. Show reclaimed bytes after.
- Mirror the health-check pattern: `select_server_interactive` →
  `check_ssh_access` → remote `bash -s` heredoc with local color vars.

**Acceptance**
- Runs read-only by default; every destructive action is opt-in per prompt.
- Prints before/after free space so the win is obvious.

**Open Qs**
- Separate target vs. a `--clean` flag on `vps-stats`? (Leaning: separate, so
  `vps-stats` stays read-only and safe to run anytime.)
- Guard level for `docker prune --volumes` (can delete data) - default OFF.

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

## 🅱️ SPRINT B - monitoring / observability box

> Read the **North Star** above first. Viewer is stateless + portable; data lives
> on the app boxes; Hybrid build (Glances for HW, home-grown sh for apps).

### B0 🔴 Fleet inventory (shared by every mon target)

**Why:** the viewer needs to know which boxes/apps exist. Avoid a hand-kept list
that drifts.

**Scope**
- Hardware: derive boxes from `hcloud server list` (already used by
  `select_server_interactive`) - the mon viewer can reuse it directly when run
  locally, or read a cached inventory when run from a dedicated mon box that may
  not hold Hetzner creds.
- Apps: need URL/health-path per app. Two candidates -
  (a) reuse the litestream labels already on each box
  (`litestream_get_bucket`/`_get_access_key` show the pattern) plus a small
  per-app health-URL registry, or
  (b) a single `mon.d/*.yml`-ish flat config the viewer reads.
- **Decision needed** before B4 (see Open Qs).

**Acceptance**
- One source of truth for "what to watch"; no duplicate lists across targets.

---

### B1 🔴 `make mon` - the viewer entrypoint (local **or** mon box)

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
- Same repo, same command, works from laptop and from mon box.

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

## ❓ Open questions to resolve before coding

1. A1: `vps-doctor` separate target vs. `vps-stats --clean`; guard for
   `docker prune --volumes`.
2. B0: app health registry = litestream-label-derived vs. a `mon.d` config file.
3. B2: glances server bind/auth (localhost+tunnel assumed).
