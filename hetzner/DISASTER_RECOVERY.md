# 🚨 Disaster Recovery Runbook

**Scope:** the box behind a client app is gone — hardware failure, accidental
deletion, provider incident, whatever. Not a planned teardown (`make
vps-down` already handles that safely on its own). This is for when there is
no live server left to SSH into.

**Design principle:** the database is **restored directly on the new
server** (R2 → box), never round-tripped through your laptop. At GB scale a
laptop round-trip means downloading the whole DB over your home connection
and re-uploading it over the slowest link you own; restoring on the box
keeps it R2 ↔ datacenter over a fat pipe, once. The only thing that comes to
your laptop is tiny backup *metadata* (Phase 2), so you still confirm the
backup is restorable **before** spending money on a new box.

## Facts this runbook depends on

- **Litestream runs at the host level** (`/etc/litestream.yml` + `systemctl`,
  binary at `/usr/local/bin/litestream`), pre-installed by cloud-init on
  every box `make vps-new` creates — not inside the Kamal container. See
  [`make vps-litestream-add`](./README.md#make-vps-litestream-add) and
  [`make vps-app-add`](./README.md#make-vps-app-add).
- **Two tiers of R2 credentials exist.** `make vps-app-add` mints scoped
  per-app tokens whose secret lives *only* in `/etc/litestream.yml` on that
  box — they die with the server. The **account-level** credential
  (`CF_R2_S3_CLIENT_ACCESS_KEY_ID` / `CF_R2_S3_CLIENT_SECRET_ACCESS_KEY` in
  your local `.env`) never touches any server and is what recovery runs on —
  the restore, all bucket ops, and token minting all use it. **It must
  survive the explosion — that's why it lives in `.env`, off the box.**
- **R2 buckets and their objects are never deleted** by any IaCarus script,
  regardless of what happens to the compute. The backup data itself is not
  at risk — only the box is gone. You **reuse the same `-bkp` bucket**; when
  Litestream starts on the restored DB it opens a **new generation** in that
  same bucket (the pre-explosion generations stay until retention prunes
  them — that's your rollback window), so there is nothing to rename or copy.
- **Ingress does not care about the new IP.** Per the root
  [`README`'s `CF_TUNNEL_TOKEN` note](../README.md#cloudflare-zero-trust-tunnel),
  a client app's Cloudflare Tunnel runs as a Kamal accessory that connects
  *outbound* using a token from that app's own `.kamal/secrets`. It
  reconnects automatically on the new box once `kamal setup` runs — no DNS
  record to touch. `deploy.yml`'s IP/port only matter for Kamal's own SSH
  access.
- **`make vps-app-add` mints fresh tokens every run and restarts Litestream
  immediately.** So (a) restore + fix ownership *before* running it, and
  (b) expect to clean up the dead box's old scoped tokens afterward
  (Phase 9) — they can't be auto-revoked because the id lived only in the
  dead box's `/etc/litestream.yml`.

## Phase 0 — Readiness checklist (do this before you ever need this doc)

- [ ] `.env` (esp. `CF_R2_S3_CLIENT_ACCESS_KEY_ID` / `_SECRET_ACCESS_KEY` and
      `CF_API_BEARER_TOKEN`) is backed up somewhere durable off this one
      machine — it's the only credential path that survives the explosion.
- [ ] The client app's `.kamal/secrets` (`RAILS_MASTER_KEY`,
      `KAMAL_REGISTRY_PASSWORD`, `KAMAL_CF_TUNNEL_TOKEN`, …) is backed up the
      same way, and you can run `kamal` from a shell where those secrets
      resolve **and the app's pinned Ruby is active** (e.g. `.ruby-version`
      via mise/rbenv). A shell on the wrong Ruby fails `kamal setup` with
      `Bundler::GemNotFound`; missing secrets fail it with
      `docker login … flag needs an argument: 'p'`. Neither is a DR problem —
      both are just "deploy from your normal, configured shell."
- [ ] `PROJECT_CODE` / `APP_LABEL` / `ENVIRONMENT`, the exact DB path inside
      its Docker volume, and the **container's numeric UID:GID** (see
      Phase 5) are written down somewhere durable — don't plan to
      reconstruct them from the dead server.
- [ ] You've dry-run Phase 2 at least once as a fire drill, so you know your
      actual RPO before an emergency, not during one.

## A note on the `litestream` binary (local machine only)

Phase 2 runs `litestream` **on your laptop**. If this machine has a Rails
app using the `litestream-ruby` gem, `litestream` on your `PATH` may resolve
to that gem's Ruby wrapper CLI, which has a different, incompatible flag
parser. Check:

```sh
file "$(readlink -f "$(which litestream)")"   # "Ruby script" == the wrong one
```

If it's the gem shim, install the real binary under a distinct name:

```sh
curl -fsSL -o /tmp/litestream.tar.gz \
  "https://github.com/benbjohnson/litestream/releases/download/v0.3.13/litestream-v0.3.13-linux-amd64.tar.gz"
tar -xzf /tmp/litestream.tar.gz -C /tmp
mv /tmp/litestream ~/.local/bin/litestream-cli
chmod +x ~/.local/bin/litestream-cli
```

(match `LITESTREAM_VERSION` in the repo's `config.sh` — currently `v0.3.13`;
swap `linux-amd64` for your platform). Use `litestream-cli` for the local
Phase 2 commands below. **On the server this problem doesn't exist** — the
box's `/usr/local/bin/litestream` is always the real binary, so Phase 5 uses
plain `litestream`.

## Phase 1 — Confirm it's actually gone

```sh
cd hetzner
make vps-list
```

If the server is still listed but just unreachable (network partition,
crashed OS), try recovery via the Hetzner console / rescue mode first —
it's faster than a full rebuild and this runbook doesn't apply. Only
continue once it's confirmed destroyed or truly unrecoverable.

## Phase 2 — Confirm the backup is restorable (metadata only, on your laptop)

Cheap and read-only: list what's in the replica **without downloading the
DB**. This is the "don't provision against a phantom backup" gate.

Set the incident variables. Fill them in with real values — **avoid
`<angle-bracket>` placeholders**, bash reads a bare `<` as input redirection
and fails with a confusing "No such file or directory".

```sh
cd iacarus            # repo root, so config.sh finds .env
source config.sh      # loads CF_R2_S3_CLIENT_URL + exports the account R2 key

export PROJECT_CODE=ccg-2026-01   # real project code
export APP_LABEL=mpl              # real app label
export ENVIRONMENT=prd            # real environment
```

Reaching R2 needs the `-config` form: `litestream`'s ad-hoc
`<REPLICA_URL>` mode only talks to real AWS S3 (no custom-endpoint flags).
The config below is the same schema production registration writes to
`/etc/litestream.yml` (`litestream_register_db()` in `../utils.sh`). Use
`snapshots` — **not** `generations`, which requires the local DB file to
exist and will error here:

```sh
DR_CONFIG=$(mktemp)
cat > "$DR_CONFIG" <<EOF
dbs:
  - path: /tmp/production.sqlite3   # arbitrary lookup key; file need not exist
    replicas:
      - type: s3
        bucket: cf-bucket-${PROJECT_CODE}-${APP_LABEL}-${ENVIRONMENT}-bkp
        region: auto
        endpoint: ${CF_R2_S3_CLIENT_URL}
        access-key-id: ${CF_R2_S3_CLIENT_ACCESS_KEY_ID}
        secret-access-key: ${CF_R2_S3_CLIENT_SECRET_ACCESS_KEY}
EOF

litestream-cli snapshots -config "$DR_CONFIG" /tmp/production.sqlite3
rm -f "$DR_CONFIG"    # contains a plaintext secret - delete immediately
```

You should see one or more generations with recent `created` timestamps.
For true freshness (the real RPO), the latest object is a WAL segment, not
the snapshot — check its timestamp directly:

```sh
aws s3api list-objects-v2 \
  --bucket "cf-bucket-${PROJECT_CODE}-${APP_LABEL}-${ENVIRONMENT}-bkp" \
  --endpoint-url "$CF_R2_S3_CLIENT_URL" \
  --query 'sort_by(Contents,&LastModified)[-1].[LastModified,Key]' --output text
```

**If this fails:** stop. Do not provision anything. Fix the credential or
bucket problem first — you cannot recover from a backup you can't reach.

## Phase 3 — Provision the replacement box

```sh
cd hetzner
make vps-new
```

Capture from the output the new **server name**, **IPv4**, and **SSH port**
(the port is randomized per box; the IPv4 may or may not be recycled).
`~/.ssh/config` is updated automatically, so `ssh $SERVER_NAME` works
immediately.

```sh
export SERVER_NAME=hetzner-vps-1   # whatever make vps-new just printed
```

Wait for cloud-init to finish before restoring — it installs the litestream
binary, Docker, and the hardening:

```sh
ssh "$SERVER_NAME" "cloud-init status --wait; which litestream && litestream version; docker --version"
```

## Phase 4 — Point Kamal at the new box

In the **client app's own repo** (not this one), edit `config/deploy.yml`:

- `servers.web` → the new IPv4 (only if it changed)
- `ssh.port` → the new SSH port

Review the diff before moving on — don't blind-`sed` a file with multiple
server/environment blocks. Nothing else changes; the Cloudflare Tunnel
reconnects on its own once `kamal setup` runs (see Facts).

## Phase 5 — Restore the DB directly on the server

Re-export `PROJECT_CODE` / `APP_LABEL` / `ENVIRONMENT` / `SERVER_NAME` if
this is a fresh terminal, and `source config.sh` again (the restore config
needs the account R2 creds).

### 5a. Create the volume and stage a temp restore config on the box

The secret travels over encrypted SSH via **stdin** (not argv, so it's not
visible in the box's process list), landing in a `0600` file:

```sh
VOL_PATH="/var/lib/docker/volumes/${APP_LABEL}_production_data/_data/production.sqlite3"

ssh "$SERVER_NAME" "docker volume create ${APP_LABEL}_production_data"

ssh "$SERVER_NAME" "cat > ~/dr-restore.yml && chmod 600 ~/dr-restore.yml" <<EOF
dbs:
  - path: ${VOL_PATH}
    replicas:
      - type: s3
        bucket: cf-bucket-${PROJECT_CODE}-${APP_LABEL}-${ENVIRONMENT}-bkp
        region: auto
        endpoint: ${CF_R2_S3_CLIENT_URL}
        access-key-id: ${CF_R2_S3_CLIENT_ACCESS_KEY_ID}
        secret-access-key: ${CF_R2_S3_CLIENT_SECRET_ACCESS_KEY}
EOF
```

### 5b. Restore straight into the volume (R2 → box)

Runs as root because the volume dir is root-owned at this point; litestream
writes a `.tmp` then renames. (Plain `litestream` here — the box's binary is
always the real one.)

```sh
ssh "$SERVER_NAME" "sudo litestream restore -config ~/dr-restore.yml '${VOL_PATH}'"
```

### 5c. Verify on the box — read-only, so it creates no WAL side-effects

Opening the DB read-write (even just to check it) would spawn `-wal`/`-shm`
files owned by whoever ran the check; `mode=ro&immutable=1` avoids that.
`sqlite3` isn't on the host by default, so use a throwaway Alpine container
(same pattern as `make vps-litestream-smoke`):

```sh
ssh "$SERVER_NAME" "docker run --rm -v ${APP_LABEL}_production_data:/data:ro alpine sh -c '
  apk add --no-cache sqlite >/dev/null 2>&1
  echo -n \"integrity: \"; sqlite3 \"file:/data/production.sqlite3?mode=ro&immutable=1\" \"PRAGMA integrity_check;\"
  echo -n \"rows: \";      sqlite3 \"file:/data/production.sqlite3?mode=ro&immutable=1\" \"SELECT COUNT(*) FROM inquiries;\"
'"
```

Expect `integrity: ok` and a row count matching what you'd expect (within
the RPO gap from Phase 2). If it's wrong, stop and investigate before going
further.

### 5d. Fix ownership to the container's UID, and clean restore orphans

**This is the step that bites if skipped.** The volume dir is `root:root`
(Docker's default for an empty volume) and the restored file is `root` (the
restore ran under sudo). The app container runs as a **non-root UID**, so
without this it fails on boot with `SQLite3::CantOpenException: unable to
open database file` during `db:prepare` — it can't create the `-wal`/`-shm`
siblings SQLite needs in a root-owned dir.

Find the UID **by number**, not by guessing a username (a host account that
happens to share the number is a coincidence):

```sh
# Fastest if the app repo is local:
grep -i '^USER' /path/to/mpl/Dockerfile
# Or ask the image directly (locally, or once it's on the box):
#   docker run --rm --entrypoint sh ghcr.io/your-org/mpl:TAG -c id
#   -> uid=1000(rails) gid=1000(rails) ...
```

Then remove the restore's temp orphans and chown the dir + file to that
numeric `UID:GID`:

```sh
DATA_DIR="/var/lib/docker/volumes/${APP_LABEL}_production_data/_data"
ssh "$SERVER_NAME" "
  sudo rm -f ${DATA_DIR}/production.sqlite3.tmp-shm ${DATA_DIR}/production.sqlite3.tmp-wal
  sudo chown 1000:1000 ${DATA_DIR} ${DATA_DIR}/production.sqlite3
"   # swap 1000:1000 for whatever the image actually reported
```

### 5e. Shred the temp config

```sh
ssh "$SERVER_NAME" "shred -u ~/dr-restore.yml 2>/dev/null || rm -f ~/dr-restore.yml"
```

## Phase 6 — Register Litestream on the new box

Now that the volume holds real, correctly-owned data, register it. This
mints fresh scoped tokens and restarts Litestream against a path that
already has good data in it (so its first generation carries your real DB).

```sh
cd hetzner
make vps-app-add
#   Project code: $PROJECT_CODE
#   App label:    $APP_LABEL
#   Environment:  $ENVIRONMENT
#   Server:       select the new box
#   DB path:      /var/lib/docker/volumes/<app_label>_production_data/_data/production.sqlite3
```

Grab the **upload-bucket credential** it prints (shown once) — you'll need
it in Phase 7 if the old `-upl` token was revoked. Then confirm Litestream
didn't leave any root-owned files in the volume (the daemon runs as the same
UID as the app here, so it shouldn't — but verify, since a root-run daemon
elsewhere could):

```sh
ssh "$SERVER_NAME" "sudo ls -la /var/lib/docker/volumes/${APP_LABEL}_production_data/_data/"
# everything except the root-owned '..' should be the container UID; the
# .production.sqlite3-litestream dir belongs to Litestream and is fine.
```

## Phase 7 — Deploy via Kamal

From the client app's repo, in a shell where the app's **pinned Ruby** is
active and its **`.kamal/secrets` resolve** (see Phase 0):

```sh
kamal setup          # fresh box: bootstraps kamal-proxy + first deploy
```

Watch it through to a healthy proxy. The entrypoint runs `db:prepare`
against the restored DB — fine for migrations *ahead* of the backup;
if the image could be *behind* the restored schema, confirm compatibility
first.

If the old `-upl` R2 token was revoked, update the app's upload credential
with the new one from Phase 6 before (or right after) deploy:

```sh
EDITOR=vim bin/rails credentials:edit --environment=$ENVIRONMENT
```

## Phase 8 — Verify, including the data itself

```sh
cd hetzner
make vps-check-health              # Litestream running + registered, box healthy
curl -sf https://YOUR-APP-DOMAIN/up   # swap in the app's real health endpoint
```

Then confirm the **data**, not just HTTP 200 — e.g. `kamal app exec` into a
Rails console and check the same row count you saw in Phase 5c still holds.

## Phase 9 — Revoke the old app's orphaned credentials

After recovery you have **4 scoped tokens** against these two buckets: the
new `-bkp` (in use by the new box's Litestream) and new `-upl`, plus the
**old `-bkp` and old `-upl`** from the dead box. Exactly two are live; the
old pair is dead weight and the old `-bkp` in particular can't be
auto-revoked (its id lived only in the dead box's `/etc/litestream.yml`).

List them — token names now carry a **UTC timestamp suffix**
(`…-bkp-20260715T224500Z`), so the stale pair is the one with the *older*
timestamp; keep the newest of each. The account-level `cf-r2-account-token`
is your `.env` key — **never delete it**:

```sh
cd iacarus && source config.sh
curl -s "${CF_API_BASE}/accounts/${CF_ACCOUNT_ID}/tokens" \
  -H "Authorization: Bearer ${CF_API_BEARER_TOKEN}" \
| jq -r '.result[] | "\(.id)  \(.name)"' | sort -k2
# revoke a stale one by id:
#   curl -s -X DELETE "${CF_API_BASE}/accounts/${CF_ACCOUNT_ID}/tokens/<ID>" \
#     -H "Authorization: Bearer ${CF_API_BEARER_TOKEN}"
```

> Alternatively, a full `make vps-app-remove` sweeps **all** of an app's
> upload tokens (live + orphaned) by prefix in one shot — but it also
> revokes the *live* backup token and deregisters Litestream, so only use it
> when you're decommissioning, not mid-recovery.

If the old box is still listed in `make vps-list` (crashed but not deleted),
run `make vps-down` to clean it up properly — its typed-name safety lock
still applies.

## Phase 10 — Postmortem

Record, while it's fresh:

- **RPO achieved**: gap between the last replicated WAL segment in R2
  (Phase 2's freshness check) and the incident time.
- **RTO achieved**: wall-clock from Phase 1 to Phase 8 passing.

Feed both back into Phase 0 — a slow RTO is usually a missing off-box backup
of `.env` / `.kamal/secrets`, or a deploy shell that wasn't ready (wrong
Ruby, unresolved secrets), not a scripting problem.
