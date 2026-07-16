# CLAUDE.md - IaCarus Developer Guide

## System Architecture

- Minimalist script-based IaC for single-box Hetzner + Cloudflare deployments.
- Hardened Ubuntu 24.04 via cloud-init.

## Development Workflows

- ALWAYS create a descriptive feature branch (`feat/...`) before modifying files.
- ALWAYS use Tutor Mode: Explain architectural choices, script parameters, or ordering constraints clearly before executing actions.

### The "commit" flow

When asked to "commit", run these steps in order:

1. **Split** the work into one commit per coherent change (docs vs. behavior).
   Split a shared file by hunk (`git apply --cached`) rather than lumping it in.
2. **Commit** each on the feature branch.
3. **Bump the version** — `VERSION := vX.Y.Z` in `config.mk` and the two
   `` `vX.Y.Z` `` mentions in `README.md`, as its own `chore: bump version to vX.Y.Z`
   commit. This MUST happen before the tag, so the tagged tree contains its own
   version number. Minor bump for behavior changes, patch for docs/fixes.
4. **Merge to `main`** with `--no-ff`, keeping the feature history visible.
5. **Tag** `main`'s tip: annotated (`git tag -a`), named `vX.Y.Z`, subject = a
   feature headline with no version in it, body = a bullet list ending with
   "Bump VERSION to vX.Y.Z in config.mk and README."
6. **Push** `main` and the tag. The remote is named **`gh`**, not `origin`:
   `git push gh main && git push gh vX.Y.Z`.
7. **Delete** the local feature branch.

- NEVER add a `Co-Authored-By` trailer to commits.

## Useful Commands

- `make setup` - Run the local wizard and check dependencies.
- `make hetzner` - Access Hetzner VPS management.
- `make cloudflare` - Access Cloudflare R2 management.
