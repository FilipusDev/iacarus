# 🦅 IaCarus: The One Person Infrastructure

![License](https://img.shields.io/github/license/FilipusDev/iacarus?style=flat-square&color=blue)

**IaCarus** is a minimalist, script-based Infrastructure as Code (IaC) toolkit
inspired by the "The One Person Framework" [article](https://world.hey.com/dhh/the-one-person-framework-711e6318).

Please read this `README` from top to bottom. (Yes, really 😅).
If you prefer debugging for 2 hours to save 5 minutes of reading -> go to [TL;DR](#🦥-tldr).

Currently (`v0.14.0`) it automates the provisioning of hardened **Hetzner VPS**
servers, and **Cloudflare R2** storage buckets using simple Bash scripts and Makefiles.

## 🗺️ TODO

Monitoring the server (disk pruning of logs/docker crap) plus near-online
observability across the fleet is planned and tracked in
[`BACKLOG.md`](./BACKLOG.md). **SPRINT A** (on-box `vps-stats` / `vps-doctor`)
and **SPRINT B** (the TUI monitoring box) are both **done** - day-to-day usage
lives in [`mon/OPERATING.md`](./mon/OPERATING.md).

## 🦥 TL;DR

1. **Setup:**

   ```bash
   ./setup.sh
   # Edit .env with your API tokens
   ```

2. **Create a Server (Hetzner):**

   ```bash
   cd hetzner
   make vps-new      # Provision a hardened VPS
   make vps-list     # See your fleet
   make vps-stats    # Read-only health snapshot (load + CPU/mem/disk/net windows)
   make vps-doctor   # Inspect disk usage + guided, opt-in cleanup
   ssh hetzner-vps-1 # Log in (Aliases auto-configured)
   ```

3. **Create Storage (Cloudflare R2):**

   ```bash
   cd cloudflare
   make bucket-new   # Interactive creation
   make bucket-list  # View buckets
   ```

## 🌐 Accounts

Yes, I know, this "stack" isn't free... BUT, it's extremely cheap.
The Hetzner Box configured by default targets their cheapest shared-vCPU
tier - check the [Hetzner console](https://console.hetzner.cloud) for
updated availability, since server types come and go over time.
We're talking about a few bucks (USD) cheap. Per VPS!

As of now (`v0.14.0`) you'll need 2 accounts: one for Hetzner and one for Cloudflare.

At Hetzner, we'll manage server boxes (VPS).
At Cloudflare, we'll manage Zero Trust tunnels and R2 storage buckets.

### Hetzner

You'll need to create an account at <https://www.hetzner.com>.
The process is pretty straightforward.

During the process you'll need to provide a payment method.

Also, you might need to go through an ID verification process, providing selfies
and document photos.

### Cloudflare

You'll need to create an account at <https://www.cloudflare.com>.
The process is (also) pretty straightforward.

During the process you might need to provide a payment method.

## 🏗️ Architecture

### The Box (Hetzner)

- **OS:** Ubuntu 24.04 (server type configurable via `.env`, see [Hetzner console](https://console.hetzner.cloud) for available types)
- **Security:** \* **Zero Open Ports:** All ingress ports (80/443) are BLOCKED by default.
  - **SSH:** Custom randomized port (1022-60022), Key-only auth, Root disabled.
  - **Networking:** Ingress handled via **Cloudflare Tunnel** (Reverse Proxy).
- **Automation:** Auto-increments server names (`vps-1`, `vps-2`), manages `~/.ssh/config` automatically.
- **Safety:** Destruction requires manual confirmation by typing the resource name.

### The Storage (Cloudflare R2)

- **S3 Compatible:** Uses AWS CLI under the hood.
- **Idempotent:** Scripts check for existence before creating.
- **Safety:** Destruction requires manual confirmation by typing the resource name.

## 🧩 Dependencies

1. At this point you must be using some Linux distro.
   If not, I don't know what to say...

   ...this toolkit is designed for Linux environments.

2. **hcloud:** the CLI interface for Hetzner Cloud. [Doc here](https://github.com/hetznercloud/cli).

3. **aws:** the CLI interface for AWS Services. [Doc here](https://github.com/aws/aws-cli).

   > No AWS Account required.
   > We use the AWS CLI strictly as a client to interact
   > with Cloudflare R2's S3-compatible API.

4. **make, nc:** pretty standard.

5. **curl, jq:** used to talk to the Cloudflare API directly (token minting/
   revocation for the multi-tenant app orchestrator, `make vps-app-add` /
   `make vps-app-remove`).

6. **glances:** the fleet hardware board (`make mon-hw`) drives it in browser
   mode. Only needed on the **viewer** - the boxes get their own copy from
   cloud-init. Install with `pacman -S glances` / `apt install glances`.

## 📝 Configuration

Copy `.env.example` to `.env` and fill with your configuration secrets.

### SSH Keys

⚠ IaCarus assumes the path `~` ($HOME) to setup and clean the following:

- `config` file, that holds the ssh connection configuration.
- `known_hosts` file, that holds the trusted ssh hosts.

If you have another "pattern" on your system, setup the SSH_HOME_PATH:

```env
SSH_HOME_PATH=$HOME/.ssh
```

- If you need to generate a new key pair:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/key-name -C "comment-to-identify-the-key"
# OR
ssh-keygen -t ed25519 -f <whatever-you-set-on_SSH_HOME_PATH>/key-name -C "comment-to-identify-the-key"
```

- If not, you could use one of your ssh keys.

```env
SSH_KEY_PATH=$SSH_HOME_PATH/key-name
SSH_PUBLIC_KEY_PATH=${SSH_KEY_PATH}.pub
SSH_PRIVATE_KEY_PATH=${SSH_KEY_PATH}
```

### Cloudflare

For the next steps, you might need to provide a valid international credit card.
Despite the generous free tier, Zero Trust and R2 Storage have paid features.

#### CLOUDFLARE API BEARER TOKEN (APP ORCHESTRATOR TOKEN FACTORY)

Used by `make vps-app-add` / `make vps-app-remove` to programmatically **mint**
and **revoke** per-app, bucket-scoped R2 tokens. This is a high-level token -
keep it safe. The per-app child tokens it creates are locked to only that app's
two buckets.

1. Access your cloudflare account: <https://dash.cloudflare.com>
2. "Manage Account" > "Account API Tokens" > "Create Token" > custom token.
3. Add TWO account permissions:
   - "API Tokens" : Edit (to create/delete tokens).
   - "Workers R2 Storage" : Edit (you can only grant R2 perms you hold).
4. Scope "Account Resources" to your account, set the TTL, and create it.
5. Optional, but recommended, configure the "Client IP Address Filtering".

In the `.env` fill the variables:

```env
# your canonical Cloudflare Account ID ("Overview" > 'Account Details').
# Shared by the token factory AND the R2 S3 endpoint further down.
CF_ACCOUNT_ID=

# the bearer token value created in step #2 above.
CF_API_BEARER_TOKEN=
```

#### CLOUDFLARE ZERO TRUST TUNNEL

1. Access your cloudflare account: <https://dash.cloudflare.com>
2. Go to "Zero Trust" (under 'PROTECT & CONNECT' menu group).
3. Go to "Connectors" (under 'Networks' menu group).
4. Click on "+ Create a tunnel" button.
5. Choose "Cloudflared" by clicking on "Select Cloudflared".
6. Give it a "Name" and click the "Save tunnel" button.
7. In the "Configure", under "Choose your environment" hit "Docker".
8. Copy the docker command under "Install and run a connector".
9. Only the token is needed, looks like: eyJhIjoiMjg3YTUyNDAyZG...

In the `.env` fill the variables:

```env
# a cloudflare tunnel to use for smoke test!
CF_TUNNEL_SMOKE_TEST_TOKEN=

# one (or more) cloudflare tunnel(s) - one for each VPS!
CF_TUNNEL_TOKEN=
```

> **Note:** `CF_TUNNEL_TOKEN` is only consumed by IaCarus's own
> `make vps-smoke-tunnel` validation - no IaCarus script runs a persistent
> tunnel on the box. For real per-app ingress, run `cloudflared` as an
> **accessory in that app's own Kamal `deploy.yml`** (its own tunnel token,
> stored in that app's own `.kamal/secrets`), for example:
>
> ```yml
> accessories:
>   cloudflared:
>     image: cloudflare/cloudflared:latest
>     roles:
>       - web
>     env:
>       secret:
>         - TUNNEL_TOKEN:KAMAL_CF_TUNNEL_TOKEN
>     cmd: "tunnel --no-autoupdate run"
> ```
>
> Point that tunnel's "Public Hostname" service at `http://kamal-proxy:80`
> (Kamal's shared reverse proxy on the box), not at the app container
> directly - Kamal renames it on every deploy. Deploying a second app to the
> same box gets its own `<service>-cloudflared` container and its own token
> automatically (Kamal names accessories `<service>-<accessory>`), so
> multiple apps' tunnels never collide - only `kamal-proxy` itself is shared.
> This keeps each app's ingress independently revocable, mirroring the
> per-app R2 token isolation `vps-app-add` already gives you (see the
> [Hetzner README](./hetzner/README.md#make-vps-app-add)).

#### CLOUDFLARE R2 STORAGE

1. Access your cloudflare account: <https://dash.cloudflare.com>
2. Go to "Overview" (under 'BUILD' > 'Storage & Databases' >
   'R2 object storage' menu group).
   > You might need click a "Create R2 Account"-like button).
3. Click on "{ } Manage" button on "API Tokens" ('Account Details' session).
4. Click on "Create Account API token" button.
5. Give it a "Name".
6. Select "Admin Read & Write" under "Permissions".
7. Leave the "TTL" as "Forever" (or select it).
8. Optional, but recommended, configure the "Client IP Address Filtering".
9. Hit the "Create Account API Token".

In the `.env` fill the variables:

```env
# cloudflare R2 storage token

#  10. copy the value under "Token value" label.
CF_R2_TOKEN=

# cloudflare R2 storage tokens : S3 interface

#  11. check this value under "Use jurisdiction-specific endpoints
#      for S3 clients:" label or in the "Overview" page
#      (under 'Account Details' session). It reuses the CF_ACCOUNT_ID set in
#      the API bearer token section above.
CF_R2_S3_CLIENT_URL=https://${CF_ACCOUNT_ID}.r2.cloudflarestorage.com

#  12. copy the value under "Access Key ID" label.
CF_R2_S3_CLIENT_ACCESS_KEY_ID=

#  13. copy the value under "Secret Access Key" label.
CF_R2_S3_CLIENT_SECRET_ACCESS_KEY=

```

## 🛠️ Toolkit Usage

Well... first things first: `git clone https://github.com/FilipusDev/iacarus.git`.

Then, `cd iacarus`.

Once there, let's run a good `make`! This will pop up a very nice message:

```sh
iacarus main ❯ make

🦅 IaCarus - CONTROL PLANE
------------------------------------------------
help                 Show this help message
setup                Run the setup script
hetzner              Enter Hetzner Control Plane
cloudflare           Enter Cloudflare Control Plane
mon                  Enter Mon (Observability) Control Plane
```

Run `make setup`.

If you jumped directly to here, you'll need to create the [Accounts](#🌐-accounts) required.
Also, back to [Configuration](#📝-configuration) section to fill all needed secrets.

After you perform all needed installations and configuration, you might see
this satisfactory output:

```sh
iacarus main ❯ make setup

🦅 IaCarus Setup Wizard
----------------------------------------
🔍 Checking dependencies...
   ✅ Found: hcloud
   ✅ Found: aws
   ✅ Found: make

📝 Configuration Setup...
✅ .env already exists.

📂 Verifying project structure...
✅ Made scripts executable.

🚀 Ready to fly!
----------------------------------------
1. Edit .env with your secrets.
2. Go to 'hetzner/' to create servers:  cd hetzner && make vps-new
3. Go to 'cloudflare/' to manage R2:    cd cloudflare && make bucket-new
----------------------------------------

```

Now, you may proceed to [Hetzner README](./hetzner/README.md)

Or to [Cloudflare README](/cloudflare/README.md)

## 📡 Observability

The fleet is watched by a **stateless, portable viewer**: monitoring data lives
on the app boxes, and the viewer is a thin client that SSHes in and renders. The
same `make` targets run from your laptop or from a dedicated always-on mon box -
where it runs is a runtime choice, never a code fork.

```sh
cd mon
make mon-apps    # live app liveness + latency board (public URLs, no creds)
make mon-hw      # live fleet hardware board (glances over SSH tunnels)
make mon-check   # what can this machine actually see?
```

Every board also has a `mon-box-*` twin that runs it **on the always-on mon
box** instead - same output, checked from a host that sits next to the fleet:

```sh
make mon-box-apps        # app board, from the mon box
make mon-box-hw          # hardware board, from the mon box
make mon-box-apps-once   # one pass, non-zero if anything is down (cron/CI)
```

**No web UIs, no time-series database, and no open ports.** Every glances server
binds `127.0.0.1` and is reached exclusively over an SSH tunnel, so zero-ingress
is a property of the process not listening rather than of a firewall rule.

An optional always-on viewer host is one command away:

```sh
cd hetzner
make vps-new-mon      # hardened box, viewer tooling, no workloads
make vps-mon-setup    # ship the viewer; it generates its OWN ssh key
```

That box is **credential-less and disposable** - it holds no monitoring data and
no infrastructure secrets, so you can destroy and rebuild it freely.

Full operating guide: [`mon/OPERATING.md`](./mon/OPERATING.md).

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
