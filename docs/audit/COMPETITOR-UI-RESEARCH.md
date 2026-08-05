# What Docker Desktop and OrbStack actually put on screen

**Researched 2026-08-05** against primary sources. This is the raw evidence; the delta and the
tickets live in [UI-FEATURE-GAP.md](UI-FEATURE-GAP.md) and `TASKS.md`.

Every claim is labelled **VERIFIED** (fetched from the vendor's own docs, changelog or issue
tracker), **REPORTED** (secondary source), or **INFERRED**. That discipline is load-bearing: most of
what is written about these two products online is stale, and this project has already been burned
by confident secondhand assertions.

## The standard we hold ourselves to

**If they can do it, we can do it better, for free, and without the overhead and cruft.**

Not as a slogan — as three specific claims we have to keep earning:

- **Better** means the thing they ship with a caveat, we ship without it. OrbStack's log search hid
  surrounding context until v2.2.0; Docker's volume export needs an account. Where a competitor's
  feature has a documented sharp edge, matching it is not enough.
- **For free** is structural, not generous. We have no account, no telemetry, no credential store and
  no commercial-use licence, so we cannot gate a feature even if we wanted to. That constrains what
  we build — see "where free changes the design" below.
- **Without the cruft** is the one we can lose by accident. Docker Desktop's UI carries an AI agent,
  a model runner, a cloud-offload pane, an extensions marketplace and a fleet-management console.
  Every one of those is a screen a developer scrolls past. **Absence is a feature we ship by
  default and can only spend once.**

---

## Docker Desktop

### Container list
- Grouped by **Compose project into collapsible entries**, taken from the top-level `name:` in
  `compose.yaml`. VERIFIED. *This is the pattern our flat list is missing.*
- Per-row hover **Actions** menu including "Open in terminal". VERIFIED.
- Inline: start/stop/pause/resume/restart, delete, copy `docker run` command, VS Code integration,
  open exposed port in browser, exec via Docker Debug. VERIFIED.
- **Unverified:** whether CPU/memory/ports appear as *list columns* or only in the Stats tab; a
  show/hide-exited toggle; bulk multi-select mechanics.

### Container detail — five tabs
**Logs · Inspect · Exec/Debug · Files · Stats.** VERIFIED.
- **Files** browses the container filesystem, edits in place, drag-and-drop transfers, downloads
  files/folders to the host. *We have no equivalent.*
- **Logs**: `Cmd/Ctrl+F` search with **regex support**, highlighted matches, `Enter`/`Shift+Enter`
  to step through, timestamps toggle, copy-all, clear, clickable links, and per-container filtering
  within a Compose app. VERIFIED.
- **Unverified:** ANSI colour rendering, wrap behaviour, explicit pause/follow, stdout/stderr
  distinction. We have all four; they may not.

### Images
Columns Tag/Image ID/Created/Size with toggleable extras; "In Use" badge; filter by In use / Unused
/ Dangling; **Local** and **Docker Hub repositories** tabs. Detail view shows history, layers, base
images, and Scout's vulnerability breakdown grouped by package with expandable fixes. VERIFIED.

### Volumes
List with name/status/created/size. A **Stored data** tab browses volume contents, right-click →
"Save as…" exports a file or folder. Export/import/clone all require **sign-in**; *scheduled*
exports require a **paid** plan. VERIFIED. *Sign-in for a local file operation is exactly the
overhead we do not have.*

### Builds
History and Active tabs; per-build **Info** with real vs accumulated time, cache usage, parallel
execution, and a breakdown across eight operation types; **Dependencies**; Source/Error tabs where a
failure is inlined against the Dockerfile; **Logs** in collapsible-per-step or plain-text form;
**History** trend charts. Plus Build Cloud integration and CI build import. VERIFIED.
*Genuinely good, and the most sophisticated screen either product has.*

### The cruft
Gordon (AI agent), Docker Model Runner (local LLMs), Docker Offload (cloud execution), the
extensions marketplace, Settings Management, Registry Access Management, Image Access Management,
Domain Audit, SSO/SCIM. VERIFIED. Most is Business-tier fleet administration.

### Pricing
Personal free (1 Scout repo, 100 pulls/hr) · Pro $9–11 · Team $15–16 · Business $24. Hardened
Desktop, RAM, Settings Management and SSO are Business-only. VERIFIED.

---

## OrbStack

Current v2.2.2 (2026-08-02). **v2.0 rebranded it "a full-fledged container IDE"** — embedded
Ghostty terminal, file manager, advanced log viewer. v2.1.0 added Liquid Glass on macOS 26. VERIFIED
via release notes.

### Log viewer — read this one carefully
- Compose logs **merged into one colour-coded stream**, one colour per service, so a request can be
  traced across services without switching views. REPORTED, consistently.
- **Their own tracker records the failure mode we currently have.** Issue #2178 (Oct 2025, v2.0.3):
  *"if you search in the logs it hides everything except the line you're searching for"* — closed
  under v2.2.0, and v2.2.2 lists "enhanced log search filtering". VERIFIED.
- Earlier: #536 asked for a text-wrap toggle; #711 reported the view auto-scrolling away while
  reading history. VERIFIED.

**Our `ContainerLogsTab` filter hides non-matching lines. That is issue #2178, unfixed, in our
product.** A competitor took two minor versions to fix it. We should not ship it at all.

### Container detail — five tabs
**Info · Logs · Terminal · Files · Activity Monitor.** REPORTED (consistent across sources).
- Terminal is one click, no typed `docker exec`. **Debug Shell** — nano, vim, htop, curl, strace,
  and 80,000+ packages via `dctl` — is the **one feature OrbStack paywalls**. VERIFIED.
- Files browses in-app; the same tree is also in Finder at `~/OrbStack/docker/containers/<name>`.
  VERIFIED.
- Activity Monitor gives per-container CPU/memory/network/disk graphs (v2.1.1), plus an `orb top`
  TUI (v2.1.2). VERIFIED.

### Native file access
Containers, images (read-only), volumes and machines all appear under `~/OrbStack` in Finder — "view,
edit, add, and delete files", no `docker cp`. VERIFIED.

### Domains and HTTPS
`<container>.orb.local`, `<service>.<project>.orb.local`, `*.k8s.orb.local`. HTTPS is zero-config via
a local reverse proxy with its own CA, auto-trusted inside containers, keys in the macOS Keychain
gated by code signature. Custom domains via a `dev.orbstack.domains` label. Visiting `http://orb.local`
renders a page linking every running container — that page *is* the domains UI; there is no dedicated
tab. VERIFIED.

### Machines
Create by name + distribution + version + architecture; per-machine CPU/memory/disk limits (v2.2.0);
bidirectional sharing (`/mnt/mac` and `~/OrbStack/<name>`). **Isolated machines** are a distinct
creation option explicitly pitched for AI-agent sandboxing — no `/mnt/mac`, no host network, SSH
agent forwarding off — with docs stating plainly it is *"not a full security boundary"* because all
machines share one kernel. VERIFIED.

### Menu bar
Start/stop/restart/delete containers and Compose projects, view logs and terminal, open a web service
in the browser, view port forwards and bind mounts, machine controls, copy IDs/addresses/domains.
Disable-able. VERIFIED. *Substantially richer than ours.*

### Settings
Memory cap default 8 GB, **dynamic** — released when unused. CPU as a percentage cap, not a
reservation. Rosetta toggle, IPv6, direct container IP access, proxy config that auto-disables on VPN
conflict, JSON engine config, containerd image store, Docker-Engine-disable switch. VERIFIED.

### Pricing
Free for personal/non-commercial. **Pro $8/user/mo** for commercial use or >$10k/year connected
income; 5 devices. Enterprise custom with SAML SSO. 30-day auto Pro trial; Pro gates Debug Shell.
VERIFIED.

### Kubernetes
Thin. Single-node cluster, shares the Docker image store (no registry push), one-click open-service-in-
browser, "enhanced Kubernetes logs UI" in v1.11.3. **No evidence of Pods/Services list or detail
screens** comparable to their Docker views. *Our Kubernetes route is already deeper than theirs.*

---

## Where "free" changes the design rather than the price

These are not features to copy cheaper. They are places where having no account makes a **different
and better** design available:

| They do | We should do |
| --- | --- |
| Volume export/import/clone behind sign-in | The same operations, no account, no gate |
| Docker Hub browsing only — no built-in UI for ghcr, ECR, or any other registry | Read-only browsing of **any** registry that serves an anonymous manifest, since we have no credential store to bias us toward one vendor |
| Scout vulnerability scanning tied to a Docker account and repo quota | `syft`/`grype` locally, no account, no quota — but `morb scan` currently references a fetch script that does not exist (DOC-5), so this is a promise we have not kept |
| Debug Shell paywalled at $8/user/mo | The one genuine feature paywall in this market. Free, and it is DIF-8 |
| Settings Management, RAM, IAM, SSO, Domain Audit, extensions marketplace, AI agent, model runner, cloud offload | **Nothing.** This is the cruft. Not building it is the product decision. |

## What we already do better

Worth stating so it is defended rather than accidentally refactored away:

- **Kubernetes depth** — real pods/nodes/events browsing; OrbStack has effectively none.
- **Logs honesty** — ANSI rendering, dropped-line markers, bounded-retention disclosure in exports,
  and a jump-to-next-stderr affordance. Docker's ANSI/wrap/stdout-vs-stderr behaviour is
  undocumented; ours is deliberate.
- **Compose source review** — declaration inspection that refuses to resolve secret values, with the
  boundary written down. Neither competitor has an equivalent.
- **Provenance** — every third-party binary SHA-256 pinned, several doubly.
- **No account, no telemetry, no commercial-use asterisk.** Structural, not a feature.

## The gaps, ranked by what would change a user's day

1. **Container filesystem browsing** — both have it, we have none. Docker's is a tab; OrbStack's is a
   tab *and* Finder.
2. **Log search that preserves context** — we currently ship OrbStack's #2178.
3. **Compose-aggregated logs**, colour-coded per service.
4. **Container list grouped by Compose project**, collapsible.
5. **A one-click terminal** — in flight as DIF-2.
6. **Per-container resource graphs** — we have a Stats tab; theirs is a graphing Activity Monitor.
7. **A richer menu-bar extra** — theirs does far more than ours.

## Sourcing gaps

Honestly recorded, because a reader should know what was not confirmed:

- Docker Desktop: container-list columns, show/hide-exited, bulk-select mechanics, Logs ANSI/wrap/
  follow behaviour, empty-state and engine-starting screens, whale-menu item list.
- OrbStack: container-list columns and sort, whether `kube-system` scaffolding is filtered from the
  Docker list, bulk actions, onboarding copy, post-v2.2.0 log-search UX beyond the changelog line.
- Neither vendor documents its empty states. Both were researched from docs and trackers, not from
  running the apps.
