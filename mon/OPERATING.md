# 📡 Operating the monitoring

How to actually *use* the observability built in SPRINT B. Two boards, one
principle: **the viewer is stateless and portable** - the same code runs from
your laptop or from the mon box, and where it runs is a runtime choice, never a
code fork.

---

## The 30-second version

```bash
# From the mon box (always-on, sits next to the fleet):
ssh hetzner-mon-1 -t 'cd /opt/iacarus/mon && make mon-apps'   # are the apps up?
ssh hetzner-mon-1 -t 'cd /opt/iacarus/mon && make mon-hw'     # are the boxes ok?

# From your laptop (identical targets, run inside mon/):
make mon-apps
make mon-hw
```

`-t` is not optional for `mon-hw`: it is a full-screen curses UI and needs a
real terminal. Without it you get a clear error rather than a traceback.

---

## What each board answers

| Target | Question | Needs | Source of truth |
|---|---|---|---|
| `make mon-check` | *Can this machine see anything?* | nothing | itself |
| `make mon-list` | *What apps exist?* | nothing | `mon/registry.json` |
| `make mon-apps` | *Are the apps up, and how slow?* | `curl` | public URLs |
| `make mon-hw` | *Are the boxes healthy?* | `ssh` + `glances` | glances on each box |
| `make vps-stats` (hetzner/) | *What did ONE box do over 5m/15m/30m/1h?* | `ssh` | sar on that box |

`mon-apps` is the one you leave running. `mon-hw` is what you open when
`mon-apps` goes yellow or red and you want to know *why*.

Both are read-only. Neither writes anything to any box.

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

## Reading `mon-hw`

`mon-hw` opens **one SSH tunnel per box**, points glances' browser mode at them,
and tears every tunnel down when you quit.

- Arrow keys + `ENTER` to drill into a box, `ESC` to come back, `q` to quit.
- The box you are running *on* appears as `(this host)` and needs no tunnel.
- A box that is down, or has no glances server, is **skipped with a warning** -
  the board still renders everything else.

If a box shows up skipped, install the server on it:

```bash
cd hetzner && make vps-glances-enable
```

---

## Why there are no open ports (do not "fix" this)

Every glances server binds **127.0.0.1 only** and is reached exclusively over an
SSH tunnel. No box exposes 61209; no firewall rule permits it.

This is deliberate and load-bearing:

- Glances' own documented default is `0.0.0.0`, and it serves the full process
  list, logged-in users and container names. A public bind would make
  zero-ingress depend on *one firewall rule* rather than on the process simply
  not listening.
- There is **no glances password**, on purpose. The only party who can reach
  `127.0.0.1` already holds a shell on the box - strictly more access than
  glances grants. SSH is the authenticator: key-only, root disabled, randomized
  port. A glances password would be a second credential system to rotate across
  every box and every viewer, protecting nobody.

The bind is pinned in a systemd drop-in **we own**
(`/etc/systemd/system/glances.service.d/iacarus.conf`), not inherited from
Ubuntu's packaging default, so a package upgrade cannot quietly expose it.

---

## The mon box

`hetzner-mon-1` is an always-on viewer host. It holds **no monitoring data**:
sar history lives on the app boxes, app checks hit public URLs.

**It is deliberately credential-less.** Its `.env` carries `MON_*` tuning only -
no Hetzner token, no Cloudflare keys. Consequences worth knowing:

- `mon_context` reports `viewer`, so `mon-hw` reads the fleet from
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

A freshly provisioned box has glances from cloud-init and needs nothing. For a
box built **before** SPRINT B:

```bash
cd hetzner
make vps-stats-enable      # sar history  -> make vps-stats windows
make vps-glances-enable    # glances      -> make mon-hw
make vps-mon-setup         # authorize the mon box on it
```

Apps register themselves: `make vps-app-add` writes `mon/registry.json` and
`make vps-app-remove` drops the entry. `make mon-register` backfills apps that
predate the registry.

---

## When something looks wrong

1. `make mon-check` - does this machine have the tooling, registry and reach?
2. `make mon-apps` - is it the app, or the whole box?
3. `make mon-hw` - CPU/mem/disk/net right now, per box.
4. `cd hetzner && make vps-stats` - what that box did over 5m/15m/30m/1h.
5. `cd hetzner && make vps-doctor` - disk filling up? guided, opt-in cleanup.
