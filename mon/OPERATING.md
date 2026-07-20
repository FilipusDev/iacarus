# 📡 Operating the monitoring

How to actually *use* the observability built in SPRINT B. Two boards, one
principle: **the viewer is stateless and portable** - the same code runs from
your laptop or from the mon box, and where it runs is a runtime choice, never a
code fork.

---

## The 30-second version

Everything runs from `mon/`. Targets come in pairs: **`mon-*`** runs the board
*here*, **`mon-box-*`** runs the same board *on the mon box*.

```bash
cd mon

make mon-box-apps        # are the apps up?      (checked from the mon box)
make mon-box-apps-once   # one pass, non-zero if anything is down (cron/CI)

make mon-apps            # same board, checked from HERE
make mon-board           # box + app time series, whole fleet on one screen
make mon-board-watch     # ...live, with sparklines
make mon-check           # what can this machine actually see?
```

The `mon-box-*` targets resolve the box from your ssh config (any `Host`
starting `hetzner-mon-`), handle the `ssh -t` pty dance, and **hand the remote
exit code back** - so `mon-box-apps-once` is directly usable in a cron. Override
the box with `MON_BOX=<alias> make mon-box-apps`. Run them *on* the mon box and
they detect it and run locally instead of SSHing to themselves.

**Which pair should you use?** `mon-box-*` is the honest one for "is my app up" -
it checks continuously from a host that is always on, sitting next to the fleet.
The local `mon-*` pair measures *your* path to the app, which is what you want
when the question is "is it slow for me?".

---

## What each board answers

| Target | Question | Needs | Source of truth |
|---|---|---|---|
| `make mon-check` | *Can this machine see anything?* | nothing | itself |
| `make mon-list` | *What apps exist?* | nothing | `mon/registry.json` |
| `make mon-apps` | *Are the apps up, and how slow?* | `curl` | public URLs |
| `make mon-board` | *What have these boxes and apps been doing?* | `ssh` | collector TSVs on each box |
| `make mon-box-*` | *…same, asked from the mon box* | `ssh` | the mon box |
| `make vps-stats` (hetzner/) | *What did ONE box do over 5m/15m/30m/1h?* | `ssh` | sar on that box |

**`mon-apps` and `mon-board` answer different questions, and both are needed.**

`mon-apps` probes the **public URL** from wherever you are: it is the only thing
that exercises DNS, Cloudflare and the tunnel, so it is the only thing that can
tell you the app is unreachable *while the box is perfectly healthy*.

`mon-board` reads what the box **recorded about itself** - loopback probes
through kamal-proxy, plus hardware sampled from `/proc`. It is history, not a
snapshot, so it answers "when did this start" rather than only "is it bad now".

The two can legitimately disagree: green on the board and red on `mon-apps`
means the app is fine and the path to it is not. That is the design working.

Both are read-only. Neither writes anything to any box.

---

## Reading `mon-board`

```
  hetzner-vps-2         cpu  12.5%  mem  39.3%  disk    25%  load 0.67
    5m cpu 15.8%  15m cpu 13.1%  1h cpu 12.6%  1d cpu 12.6%
    * mpl            200      42ms  cpu  2.54%  mem 118MB  R3   down 0/114
      5m 44.1ms   15m 45.2ms   1h 47.7ms   1d 47.8ms
```

- The **first line per box** is *now*; the line under it is the same metric
  averaged over each window, so a spike and a trend are never confused.
- **`down N/M`** is down-samples over total samples in the last hour. An app
  that flaps reads as `14/114` - a single up/down snapshot would show it green
  between flaps and tell you nothing.
- The **restart count** matters more than it looks: an app can be "up" at every
  sample and still be crash-looping, and this is what catches that.
- A missing value renders `-`, never `0`. The collector emits `-` when something
  genuinely could not be measured (first sample after boot, container gone
  mid-deploy), and averaging a fabricated zero would quietly drag a window down.

`make mon-board-watch` redraws with sparklines instead of window columns - use it
while you are actively watching something. `make mon-board-once` is the
scriptable form and **exits non-zero if anything is down**.

### If a box says "no collector installed"

```bash
cd hetzner && make vps-collect-enable
```

That ships `iacarus-collect`, its systemd timer and its logrotate policy. It is
idempotent, and re-running it is also how you deploy a *changed* collector.

---

## Reading `mon-apps`

```
● mpl    200      1ms     8ms    25ms   139ms   173ms     55d
```

Columns are per-phase, in milliseconds: DNS → CONN → TLS → TTFB → TOTAL, then
days until the certificate expires. Colour is judged on **TOTAL**.

**Thresholds are a property of the observer, not the app.** The same healthy app
measures ~250ms from Brazil and ~170ms from Helsinki, so the mon box ships
tighter defaults (`300`/`1000` ms) than the laptop (`1200`/`3000` ms). Tune them
in the relevant `.env` - never assume one machine's numbers travel to another.

`make mon-apps-once` does a single pass and **exits non-zero if anything is
down** - that is the form to put in a cron or a CI step.

---

## Why there are no open ports (do not "fix" this)

Monitoring data is read over **SSH only**. No box exposes a metrics port, and no
firewall rule permits one.

This is deliberate and load-bearing: zero-ingress is a property of **nothing
listening**, not of a firewall rule being correct. A metrics port would invert
that - a single misapplied rule would be all that stood between the internet and
the box's process list, container names and logged-in users.

SSH is the only authenticator: key-only, root disabled, randomized port. Whoever
can read the samples already holds a shell on the box, which is strictly more
access than the samples grant - so a second credential system to rotate across
every box and every viewer would protect nobody.

---

## The mon box

`hetzner-mon-1` is an always-on viewer host. It holds **no monitoring data**:
sar history lives on the app boxes, app checks hit public URLs.

**It is deliberately credential-less.** Its `.env` carries `MON_*` tuning only -
no Hetzner token, no Cloudflare keys. Consequences worth knowing:

- `mon_context` reports `viewer`, so the boards read the fleet from
  `registry.json` rather than from Hetzner. **A box with no registered app is
  invisible from the mon box** (it is visible from your laptop, which can ask
  Hetzner directly). The mon box adds *itself* regardless.
- Losing the mon box costs you nothing and grants an attacker nothing.

Its SSH key was **generated on the box itself**; the private half has never
existed anywhere else. Your laptop key was never copied there. To revoke the mon
box's access to the fleet, drop its public key from each app box's
`~/.ssh/authorized_keys`.

### Keeping it current

The mon box holds a *copy* of the viewer, not a git checkout. After changing
anything in `mon/`, `config.sh`, `utils.sh`, or after adding/removing an app:

```bash
cd hetzner && make vps-mon-setup     # idempotent - re-run as often as you like
```

That re-ships the viewer, re-copies the registry, re-authorizes the key on every
app box, and rewrites the mon box's ssh config **in full** (so a destroyed and
recreated box leaves no stale entry behind).

### Rebuilding it from scratch

It is stateless, so this is safe and takes about three minutes:

```bash
cd hetzner
make vps-down            # pick hetzner-mon-1
make vps-new-mon
make vps-mon-setup
```

---

## New app box checklist

A freshly provisioned box needs nothing. For a box built **before** SPRINT B:

```bash
cd hetzner
make vps-stats-enable      # sar history      -> make vps-stats windows
make vps-collect-enable    # sample collector -> make mon-board
make vps-mon-setup         # authorize the mon box on it
```

A **freshly provisioned** box still needs `make vps-collect-enable`: the
collector is shipped over SSH rather than embedded in cloud-init, so there is
one copy of it in the repo instead of two that drift.

Apps register themselves: `make vps-app-add` writes `mon/registry.json` and
`make vps-app-remove` drops the entry. `make mon-register` backfills apps that
predate the registry.

---

## When something looks wrong

1. `make mon-check` - does this machine have the tooling, registry and reach?
2. `make mon-apps` - is it the app, or the whole box?
3. `cd hetzner && make vps-stats` - what that box did over 5m/15m/30m/1h.
5. `cd hetzner && make vps-doctor` - disk filling up? guided, opt-in cleanup.
