# Documentation index

Eighty-odd documents accumulated here with no entry point, which the repo audit called out as its
own finding. This is the entry point. **Start here, not with a directory listing.**

## If you are new

| You want to | Read |
| --- | --- |
| See what it actually looks like | [gallery/](gallery/) — real WindowServer captures, per route |
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
[build.md](build.md) · [background-service.md](background-service.md) ·
[first-run.md](first-run.md) ·
[design/PATCH-FREE-PUBLISH-ALL.md](design/PATCH-FREE-PUBLISH-ALL.md) — why `docker run -P` works on
stock upstream `dockerd`, through its own `--userland-proxy-path` hook, with no engine patch. Read
this before believing any older document that mentions a Moby patch.

**Docker compatibility** — [parity.md](parity.md) · [compat.md](compat.md) ·
[docker-engine-compatibility-inventory.md](docker-engine-compatibility-inventory.md) ·
[dynamic-port-allocation.md](dynamic-port-allocation.md) ·
[fixed-udp-port-publication-design.md](fixed-udp-port-publication-design.md) ·
[clean-profile-acceptance.md](clean-profile-acceptance.md) ·
[ecosystem-acceptance.md](ecosystem-acceptance.md) ·
[design/ZERO-CONFIG-DISCOVERY.md](design/ZERO-CONFIG-DISCOVERY.md) — how Testcontainers and Dev
Containers find Morbstack with nothing configured, and why silent fallback to another daemon was the
bug worth fixing

**Features** — [builds.md](builds.md) · [k8s.md](k8s.md) · [exec.md](exec.md) ·
[shares.md](shares.md) · [sharing.md](sharing.md) · [live-share-bridge.md](live-share-bridge.md) ·
[domains.md](domains.md) · [machines.md](machines.md) · [migrate.md](migrate.md) ·
[export.md](export.md) · [debug.md](debug.md) · [amd64.md](amd64.md) ·
[image-discovery.md](image-discovery.md) · [mcp.md](mcp.md) ·
[compose-source-validation.md](compose-source-validation.md) ·
[compose-environment-secrets-inspection.md](compose-environment-secrets-inspection.md)

**Design** — [design/README.md](design/README.md) gives the reading order; it is led by
[design/DECISIONS.md](design/DECISIONS.md),
[design/NATIVE-MACOS-PLAYBOOK.md](design/NATIVE-MACOS-PLAYBOOK.md),
[design/HIG-COVERAGE-AUDIT.md](design/HIG-COVERAGE-AUDIT.md),
[design/tahoe/HIG-FINDINGS.md](design/tahoe/HIG-FINDINGS.md) (verbatim-fetched Apple guidance) and
[design/ACCESSIBILITY-IDENTIFIERS.md](design/ACCESSIBILITY-IDENTIFIERS.md)

**Competitive position** — [COMPETITIVE-GAPS.md](COMPETITIVE-GAPS.md) ·
[comparison.md](comparison.md) · [audit/COMPETITOR-UI-RESEARCH.md](audit/COMPETITOR-UI-RESEARCH.md) ·
[audit/UI-FEATURE-GAP.md](audit/UI-FEATURE-GAP.md) ·
[audit/CAPABILITY-GAP.md](audit/CAPABILITY-GAP.md)

The last two are companions and should be read together: **UI-FEATURE-GAP** is the delta in
**screens**, **CAPABILITY-GAP** is the delta in **capabilities** — performance, networking, disk,
proxies, integrations, migration — whether or not any of it is visible in a window. Both rank their
findings by what changes a user's day, and both record skip verdicts as product decisions rather
than omissions.

**Audits** — [audit/](audit/). [audit/MASTER-AUDIT.md](audit/MASTER-AUDIT.md) is the entry point, but
it is dated 2026-08-03 and its companion table does not list anything written since. The rest:

| Audit | Asks |
| --- | --- |
| [audit/ARCHITECTURE-AUDIT.md](audit/ARCHITECTURE-AUDIT.md) | is the structure right and will it hold — protocol contract, concurrency, module graph. States up front that fail-open analysis was **not** covered. |
| [audit/TECHNOLOGY-AUDIT.md](audit/TECHNOLOGY-AUDIT.md) | are the platform bets sound. Bet 6 was decided by TECH-1; see the dated note in that section. |
| [audit/TASTE-REVIEW.md](audit/TASTE-REVIEW.md) | is the UI *good*, as opposed to not broken. Every finding marked LAW or TASTE. Companion to the defect register in [audit/UI-AUDIT.md](audit/UI-AUDIT.md). |
| [audit/INPUT-VALIDATION-REVIEW.md](audit/INPUT-VALIDATION-REVIEW.md) | can a hostile message off a socket hurt us — line-by-line over the guest wire parsers, the MCP server, and every process-spawning site. Names what it did not review. |
| [audit/ECOSYSTEM-MATRIX.md](audit/ECOSYSTEM-MATRIX.md) | do Testcontainers and Dev Containers work, run live against the dev daemon. |
| [audit/PROXY-FRAMING.md](audit/PROXY-FRAMING.md) | the fail-open preflight defect, its fix, and the streaming paths the fix could have broken. |
| [audit/CONCURRENCY-PROTOCOL-FIXES.md](audit/CONCURRENCY-PROTOCOL-FIXES.md) | what CONC-2..5 / PROTO-1..7 / MOD-4 actually changed, including which races no unit test can reproduce. |
| [audit/ENGINE-MATRIX.md](audit/ENGINE-MATRIX.md) | the first full runtime run against a rebuilt guest. Dated evidence; its publish-all sections describe a deleted mechanism. |
| [audit/BUILD-REPAIR.md](audit/BUILD-REPAIR.md) | every compile error on a branch of never-compiled commits, and every place intent had to be inferred. |

Five of them ([MASTER-AUDIT](audit/MASTER-AUDIT.md), [PRODUCT-AUDIT](audit/PRODUCT-AUDIT.md),
[TECHNOLOGY-AUDIT](audit/TECHNOLOGY-AUDIT.md), [ENGINE-MATRIX](audit/ENGINE-MATRIX.md),
[PROXY-FRAMING](audit/PROXY-FRAMING.md)) carry a dated staleness note about the deleted Moby patch.
Believe the note, not the finding it sits above.

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
