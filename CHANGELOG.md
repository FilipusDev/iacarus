# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/). `Unreleased` accumulates; the bump
commit rolls it into a `vX.Y.Z` section (Fleet Common Core). Sections at and below v0.20.0 are
seeded from the annotated tags that predate this file.

## Unreleased

### Changed

- `fleet-doctor` proves the single-source common core (ADR-0010): the three `~/.claude`
  symlinks resolve into daedalus, every consumer `CLAUDE.md` carries the
  `@~/.claude/fleet-core.md` import line (argus included — v1's hash check had never been
  taught about it), no duplicated block survives, and every repo carries a `CHANGELOG.md`.
- `CLAUDE.md` — the duplicated Fleet Common Core block replaced by the import line (ADR-0010).
- `README.md` — the monitoring TODO now points at the Argus/Talos carve-out (ADR-0008/0009)
  instead of the finished mon sprints.

## v0.20.0 — replace glances with an on-box collector and fleet board

## v0.19.0 — pin the viewer's glances to the fleet's version

## v0.18.3 — gate stopped-container deletion behind its own prompt

## v0.18.2 — name a glances major mismatch instead of a false outage

## v0.18.1 — config resolves from its own location and fails loudly

## v0.18.0 — doctor resolves make targets against the dir docs name

## v0.17.0 — doctor catches restated facts that drift

## v0.16.1 — app credential snippet nests under cf.r2

## v0.16.0 — control-plane secrets resolve from 1password

## v0.15.0 — registry drift detection and honest floating-tool rows

## v0.14.0 — fleet-wide documentation invariants and pinned-version reminders

## v0.13.2 — disable glances connections plugin that blanks the hardware board

## v0.13.1 — stop background tunnels stealing the board's keystrokes

## v0.13.0 — run the mon boards on the mon box from a local target

## v0.12.0 — watch the fleet hardware over ssh tunnels from a stateless mon box

## v0.11.1 — extract the sar window parsers into a shared remote lib

## v0.11.0 — render app liveness and latency in the mon board

## v0.10.0 — add the stateless mon viewer control plane

## v0.9.0 — track monitored apps in a jq-maintained registry

## v0.8.0 — ship docker buildx on provisioned boxes

## v0.7.2 — keep vps-stats windows intact across midnight

## v0.7.1 — document sprint a commands in the hetzner readme

## v0.7.0 — add vps-doctor for disk inspection and guided cleanup

## v0.6.1 — fix 2-min sysstat sampling on ubuntu 24.04

## v0.6.0 — add on-box health stats backed by sysstat

## v0.5.0 — apply r2 cors to the upload bucket during app provisioning

## v0.4.2 — polish the readme todo heading

## v0.4.1 — register monitoring & observability backlog

## v0.4.0 — server-side disaster recovery and traceable r2 token names

## v0.3.1 — repair make setup bootstrap and clarify cloudflare tunnel/token docs

## v0.3.0 — multi-tenant app orchestrator: r2 buckets, isolated tokens, and litestream in one shot

## v0.2.0 — multi-app litestream backup replication to cloudflare r2

## v0.1.1 — host hardening: swap, docker log rotation, weekly prune cron

## v0.1.0 — hetzner vps and cloudflare r2 support
