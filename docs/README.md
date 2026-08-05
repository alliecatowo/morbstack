# Documentation index

Forty-odd documents accumulated here with no entry point, which the repo audit called out as its own
finding. This is the entry point. **Start here, not with a directory listing.**

## If you are new

| You want to | Read |
| --- | --- |
| Understand what Morbstack is and how it works | [architecture.md](architecture.md) |
| Build and run it | [build.md](build.md), then `CLAUDE.md` in the repo root for the landmines |
| Know what is actually done versus claimed | [../TASKS.md](../TASKS.md) — the ticket board |
| Know what we build next and in what order | [MASTER-PLAN.md](MASTER-PLAN.md) |
| Work on this repo as an agent | `CLAUDE.md`, then [development/](development/) |

## The three documents that outrank the rest

- **[../TASKS.md](../TASKS.md)** — every audit finding, ticketed. If a claim here and a ticket there
  disagree, the ticket is newer.
- **[MASTER-PLAN.md](MASTER-PLAN.md)** — ordering authority. Operational integrity → parity →
  differentiation, and nothing moves down the list until the thing above it is *proven at runtime*.
- **[design/DECISIONS.md](design/DECISIONS.md)** — binding design law. "If the system draws it, let
  the system draw it." Not advisory.

## Evidence vocabulary

Every status in this repo uses one of three words. The old word "implemented" is banned, because it
silently merged the first two and that is how three headline features shipped having never run:

| Word | Means |
| --- | --- |
| `source-only` | The code exists and compiles. Nothing has run it. |
| `runs-here` | Executed on a developer machine against the current build, with recorded output. |
| `accepted` | Passed the clean-profile matrix on a machine that never had Docker. |

## By subject

**How it works** — [architecture.md](architecture.md) · [protocol.md](protocol.md) ·
[build.md](build.md) · [background-service.md](background-service.md) · [first-run.md](first-run.md)

**Docker compatibility** — [parity.md](parity.md) · [compat.md](compat.md) ·
[docker-engine-compatibility-inventory.md](docker-engine-compatibility-inventory.md) ·
[dynamic-port-allocation.md](dynamic-port-allocation.md) ·
[fixed-udp-port-publication-design.md](fixed-udp-port-publication-design.md) ·
[clean-profile-acceptance.md](clean-profile-acceptance.md) ·
[ecosystem-acceptance.md](ecosystem-acceptance.md)

**Features** — [builds.md](builds.md) · [k8s.md](k8s.md) · [exec.md](exec.md) ·
[shares.md](shares.md) · [sharing.md](sharing.md) · [live-share-bridge.md](live-share-bridge.md) ·
[domains.md](domains.md) · [machines.md](machines.md) · [migrate.md](migrate.md) ·
[export.md](export.md) · [debug.md](debug.md) · [amd64.md](amd64.md) ·
[image-discovery.md](image-discovery.md) · [mcp.md](mcp.md) ·
[compose-source-validation.md](compose-source-validation.md) ·
[compose-environment-secrets-inspection.md](compose-environment-secrets-inspection.md)

**Design** — [design/](design/), led by [design/DECISIONS.md](design/DECISIONS.md) and
[design/tahoe/HIG-FINDINGS.md](design/tahoe/HIG-FINDINGS.md) (verbatim-fetched Apple guidance) and
[design/ACCESSIBILITY-IDENTIFIERS.md](design/ACCESSIBILITY-IDENTIFIERS.md)

**Competitive position** — [COMPETITIVE-GAPS.md](COMPETITIVE-GAPS.md) ·
[comparison.md](comparison.md) · [audit/COMPETITOR-UI-RESEARCH.md](audit/COMPETITOR-UI-RESEARCH.md) ·
[audit/UI-FEATURE-GAP.md](audit/UI-FEATURE-GAP.md)

**Audits** — [audit/](audit/). [audit/MASTER-AUDIT.md](audit/MASTER-AUDIT.md) is the entry point.

**Publishing** — [PUBLISHING.md](PUBLISHING.md)

## Documents that are history, not instructions

These record what was true on a date. They are kept as evidence and are **not** current guidance;
several describe mechanisms since deleted. Do not act on them without checking the ticket board
first.

- [claude-audit-handoff-2026-08-03.md](claude-audit-handoff-2026-08-03.md)
- [claude-continuation-handoff-2026-08-03.md](claude-continuation-handoff-2026-08-03.md)
- [final-implementation-audit-2026-08-03.md](final-implementation-audit-2026-08-03.md)
- [TRUTHFULNESS-PASS.md](TRUTHFULNESS-PASS.md) — what 26 doc claims were corrected on 2026-08-03, and
  the 17 deliberately left alone
- [BACKLOG.md](BACKLOG.md) — superseded by [../TASKS.md](../TASKS.md)
- [roadmap.md](roadmap.md), [drop-in-delivery-plan.md](drop-in-delivery-plan.md),
  [competitive-capability-roadmap.md](competitive-capability-roadmap.md),
  [product-audit.md](product-audit.md) — superseded by [MASTER-PLAN.md](MASTER-PLAN.md) and
  [../TASKS.md](../TASKS.md)
- [design/pass2/](design/pass2/) — a superseded design pass, kept because its reasoning is cited
  elsewhere. Five of its filenames duplicate its parent directory; the parent wins.

**This proliferation is itself a known problem.** SP-7 in the ticket board proposes collapsing the
overlapping status documents into one generated file, because six of them reconciled by hand is how
they came to disagree in both directions at once.
