# CLAUDE.md - IaCarus Developer Guide

## System Architecture

- Minimalist script-based IaC for single-box Hetzner + Cloudflare deployments.
- Hardened Ubuntu 24.04 via cloud-init.

@~/.claude/fleet-core.md

## Repo-local rules

- **Version artifact:** `VERSION := vX.Y.Z` in `config.mk`, plus the two `` `vX.Y.Z` `` mentions in
  `README.md`. Behavior here means scripts, cloud-init, or Makefile targets — what a box actually
  runs. Currently `v0.20.0`.
- **Everything is interactive and confirmation-gated.** Destruction requires typing the resource
  name; never add a non-interactive bypass flag to a destructive target.
- **New capability = new script + a `## `-commented Make target** in that domain dir, so the
  self-documenting help table picks it up automatically.

## Useful Commands

- `make setup` - Run the local wizard and check dependencies.
- `make hetzner` - Access Hetzner VPS management (provision, stats, app orchestrator).
- `make cloudflare` - Access Cloudflare R2 management (bucket lifecycle, smoke tests).
- `make mon` - Access the stateless observability and fleet monitoring control plane.
