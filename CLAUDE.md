# CLAUDE.md - IaCarus Developer Guide

## System Architecture

- Minimalist script-based IaC for single-box Hetzner + Cloudflare deployments.
- Hardened Ubuntu 24.04 via cloud-init.

<!-- FLEET-COMMON-CORE v1 — byte-identical in every fleet repo. Edit here, propagate to all. -->

## Fleet Common Core

These rules are identical in `iacarus`, `daedalus`, `_template_rails-app`, every stamped app, and
the workspace root. They are duplicated rather than referenced because stamped apps live outside
the workspace and never load its `CLAUDE.md`. Change one, change all.

### Git workflow (STRICT)

- **Branch always.** Every modification happens on a descriptive topic branch (`feat/…`, `fix/…`,
  `docs/…`, `chore/…`). Never commit directly to `main`.
- **One-line Conventional Commits.** `feat:`, `fix:`, `chore:`, `docs:` — a single concise summary
  line. No bodies, no bullet lists, no narrative in the log; prose belongs in docs.
- **Never add a `Co-Authored-By` trailer.**
- **Split by coherence.** One commit per coherent change (docs vs behavior), splitting a shared
  file by hunk (`git apply --cached`) rather than lumping them together.
- **Merge with `--no-ff`, keeping git's own subject:** `Merge branch '<topic>'`, nothing else. Every
  integration is then a knot on `main` whose subject names the branch it closed. Restating a topic
  commit's subject on its merge makes the log read as the same commit twice — the branch name is
  the one thing the merge knows that its commits do not.
- **Behavior-pure versioning.** Versions track what actually runs. Docs-only changes merge with no
  bump and no tag. Behavior changes get an isolated `chore: bump version to vX.Y.Z` commit *on the
  topic branch* (so the tagged tree carries its own version), then an annotated tag on the merge
  commit. The tag subject is a clean lowercase headline with no version text inside it. **Minor**
  for a new capability, **patch** for a bugfix.
- **Every repo that *runs* is versioned.** The control plane and every app stamped from
  `_template_rails-app` — the canary first — carry a version artifact and the rule above from their
  first commit, so a deployed tree can always name itself. A repo that only *describes* carries
  none, and says so in its repo-local rules rather than leaving it to be inferred.
- **The remote is `gh`, never `origin`.** `git push gh main`, plus `git push gh vX.Y.Z` when tagged.
- **Close the branch in one sitting:** merge → tag, if behavior changed → `git push gh main` and the
  tag → delete the topic branch. A branch left merged-but-unpushed, or a bump left untagged, is
  exactly the drift the rest of this protocol exists to prevent.

### Working rules

- **Propose before executing** anything touching or creating more than ~2 files, and anything that
  provisions, destroys, or deploys real infrastructure. Write the plan in the terminal and wait.
- **Tutor Mode.** The developer is learning Rails and infrastructure. Explain architectural choices,
  parameters, and ordering constraints *before* executing, and deconstruct syntax when asked — the
  *why*, not merely the *what*.
- **Report honestly.** Failing tests are reported with their output, never papered over. A skipped
  step is stated as skipped. A red gate blocks any deploy proposal.
- **Git safety baseline.** The developer validates with `git diff` after each micro-step; keep
  changes isolated and declarative.

### Secrets (1Password)

The fleet keeps no plaintext secrets on disk. 1Password holds the values; repos hold only
*references*.

- **Two vaults, and the split is load-bearing.** `DevOps` holds what apps and CI consume (the
  `-upl` credential, tunnel token, SES pair, ghcr PAT, `master.key`). `DevOps-Recovery` holds the
  R2 `-bkp` credential and nothing else, and **no service account is ever granted access to it**
  (ADR-0002, ADR-0007).
- **A reference is not a secret.** `op://<vault>/<item>/<section>/<field>` names where a value lives
  and cannot reveal one. Files of references (`*.env.op`) are committed on purpose. A literal
  secret in a tracked file is a hard failure.
- **Injection is `op run`.** `op run --env-file=<file>.op -- <cmd>` resolves references into the
  child process only — never to disk, shell history, or an image. `op read "op://…"` fetches one.
- **Non-secrets stay literal.** `op run` passes through values that are not `op://` references, so
  public hostnames, bucket names, and regions belong inline. A file where every line is a reference
  trains the reader to stop distinguishing which ones matter.
- **Auth is environmental, never textual.** On a laptop `op` resolves through the desktop app
  (biometric prompt per command). In CI, `OP_SERVICE_ACCOUNT_TOKEN` is set and `op` never prompts.
  The same commands work in both; nothing branches on which. Rehearse CI locally with `op-ci-mode`,
  which reads the token from 1Password into a subshell — the token itself never lands on disk.
- **Never print a secret.** Pipe `op` output into the next command; never echo a value into a log,
  a terminal, or a transcript. If a value is exposed anyway, treat it as burned and rotate it.

<!-- /FLEET-COMMON-CORE -->

## Repo-local rules

- **Version artifact:** `VERSION := vX.Y.Z` in `config.mk`, plus the two `` `vX.Y.Z` `` mentions in
  `README.md`. Behavior here means scripts, cloud-init, or Makefile targets — what a box actually
  runs. Currently `v0.18.0`.
- **Everything is interactive and confirmation-gated.** Destruction requires typing the resource
  name; never add a non-interactive bypass flag to a destructive target.
- **New capability = new script + a `## `-commented Make target** in that domain dir, so the
  self-documenting help table picks it up automatically.

## Useful Commands

- `make setup` - Run the local wizard and check dependencies.
- `make hetzner` - Access Hetzner VPS management (provision, stats, app orchestrator).
- `make cloudflare` - Access Cloudflare R2 management (bucket lifecycle, smoke tests).
- `make mon` - Access the stateless observability and fleet monitoring control plane.
