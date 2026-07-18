# CLAUDE.md - IaCarus Developer Guide

## System Architecture

- Minimalist script-based IaC for single-box Hetzner + Cloudflare deployments.
- Hardened Ubuntu 24.04 via cloud-init.

## Development Workflows

- ALWAYS create a descriptive feature or fix branch (`feat/...`, `fix/...`, `docs/...`) before modifying files.
- ALWAYS use Tutor Mode: Explain architectural choices, script parameters, or ordering constraints clearly before executing actions.

### The "commit" flow (STRICT)

When asked to "commit", run these steps in order:

1. **Split** the work into one commit per coherent change (docs vs. behavior). Split a shared file by hunk (`git apply --cached`) rather than lumping it in.
2. **Commit Hygiene:** Every commit MUST use **Conventional Commit** headers (`feat:`, `fix:`, `chore:`, `docs:`). Messages MUST be restricted to a **single concise, high-level summary line**. Narrative essays, paragraphs, or descriptive multi-line bodies inside the git log are strictly forbidden.
3. **Version only on behavior.** Versions track what a box actually runs, not prose. If the change set touches **runtime behavior** (scripts, cloud-init, Makefile targets), bump; if it is **docs-only** (README, BACKLOG, comments), do NOT bump or tag — skip to step 4, and in step 6 push only `main`.
   When bumping: `VERSION := vX.Y.Z` in `config.mk` and the two `` `vX.Y.Z` `` mentions in `README.md`, as its own clean `chore: bump version to vX.Y.Z` commit on the topic branch. This MUST happen before the tag, so the tagged tree contains its own version number. **Minor** bump for a new capability, **patch** for a bugfix.
4. **Merge to `main`** with `--no-ff` (non-fast-forward), explicitly keeping the feature history visible as a distinct merge commit.
5. **Tag** (behavior changes only — skip for docs-only) `main`'s tip: minted as an **annotated tag** (`git tag -a vX.Y.Z`). The tag subject must be a clean, single-line headline with **no version text inside the subject line** (e.g., `git tag -a v0.8.0 -m "install docker buildx on provisioned boxes"`). Keep tag text crisp and devoid of narrative storytelling.
6. **Push** the remote named **`gh`**, not `origin`: `git push gh main && git push gh vX.Y.Z` for a behavior change, or just `git push gh main` for a docs-only merge.
7. **Delete** the local feature branch.

- NEVER add a `Co-Authored-By` trailer to commits.

## Useful Commands

- `make setup` - Run the local wizard and check dependencies.
- `make hetzner` - Access Hetzner VPS management (provision, stats, app orchestrator).
- `make cloudflare` - Access Cloudflare R2 management (bucket lifecycle, smoke tests).
- `make mon` - Access the stateless observability and fleet monitoring control plane.
