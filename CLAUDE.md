# CLAUDE.md - IaCarus Developer Guide

## System Architecture

- Minimalist script-based IaC for single-box Hetzner + Cloudflare deployments.
- Hardened Ubuntu 24.04 via cloud-init.

## Development Workflows

- ALWAYS create a descriptive feature branch (`feat/...`) before modifying files.
- ALWAYS use Tutor Mode: Explain architectural choices, script parameters, or ordering constraints clearly before executing actions.

## Useful Commands

- `make setup` - Run the local wizard and check dependencies.
- `make hetzner` - Access Hetzner VPS management.
- `make cloudflare` - Access Cloudflare R2 management.
