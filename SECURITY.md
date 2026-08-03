# Security Policy

## Supported versions

Morbstack is pre-release (milestone M0 — see
[`docs/roadmap.md`](docs/roadmap.md)) and has never had a tagged release.
**Only the latest commit on `main` is supported.** There is no LTS branch,
no backport policy, and no version matrix — if you report an issue against
anything other than current `main`, the first ask will be to reproduce it
there.

This will change once Morbstack starts tagging releases (see
[`docs/PUBLISHING.md`](docs/PUBLISHING.md) and, once it exists,
`docs/RELEASING.md`); this file will be updated at that point to name a
real supported-versions policy instead of "latest `main`."

## Reporting a vulnerability

**Please do not open a public GitHub issue for a security vulnerability.**
Use [GitHub Security Advisories](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing/privately-reporting-a-security-vulnerability)
("Report a vulnerability" under this repository's Security tab) — this
lets us discuss and fix the issue in private before it's public, and
GitHub gives you credit in the resulting advisory once it's disclosed.

If GitHub Security Advisories isn't available or workable for you, email:

TODO(human): insert a real security-contact email address here (e.g.
security@morbstack.dev), then remove this TODO marker. Until this is
filled in, the GitHub Security Advisory flow above is the only channel.

Please include:

- What you found and why you believe it's a security issue (see "In
  scope" below — if you're not sure, report it anyway and let us make
  that call).
- Steps to reproduce, or a proof of concept.
- The output of `morb version` and `morb doctor`, and your macOS
  version/Mac model, if the issue is host-side.
- Whether you're aware of it being publicly known or exploited already.

### Response time

Morbstack is currently maintained by one person in their spare time, so
please read the following as an honest description of what's achievable,
not a corporate SLA:

- **Acknowledgment**: best effort within a few days, not hours. There is
  no 24-hour or same-day commitment — a project this size cannot make one
  truthfully, and a promise it can't keep is worse than no promise.
  If you haven't heard back after a week, it's fair to follow up; the
  report may have been missed rather than triaged and declined silently.
- **Fix timeline**: depends entirely on severity and complexity. A
  critical, easily-exploited issue (for example, something that lets an
  unprivileged local process reach the Docker socket or escape the guest)
  gets prioritized over everything else in the project; a low-severity
  finding may wait behind other work. There is no fixed SLA by severity
  tier at this stage.
- **Disclosure**: coordinated disclosure is the default — we'll agree a
  disclosure date with you once a fix is ready or a reasonable amount of
  time has passed without one, rather than disclosing unilaterally.

## Threat model

Morbstack is host software with real privilege, so it's worth being
specific about what that privilege actually is and where the boundaries
are, rather than leaving it implicit.

- **`morbstackd` holds the `com.apple.security.virtualization`
  entitlement** and boots a root Linux guest via
  `Virtualization.framework`. Anything that lets an untrusted party
  influence what `morbstackd` boots, or how it configures the VM (kernel
  command line, shared directories, entitlements), is a security issue.
- **The Docker socket at `~/.morbstack/run/docker.sock` is
  root-equivalent to the guest.** Anyone who can write to that socket can
  run arbitrary containers as root in the guest, and — via bind mounts —
  read and write any host directory listed in `shared_paths`
  (`/Users`, `/Volumes`, `/private/tmp` by default; see
  [`docs/sharing.md`](docs/sharing.md)). This is inherent to how Docker
  sockets work everywhere, not Morbstack-specific, but it means **local
  access control to that socket matters**: a bug that widens who/what can
  reach it (e.g. a permissions regression on the socket file, or a
  network listener where only a Unix socket should exist) is in scope.
- **VirtioFS shares expose host directories to every container.** A path
  under a shared root is readable and writable by any container you run,
  including one just pulled from a registry — this is documented,
  expected behavior (see `docs/sharing.md`), not itself a
  vulnerability. What *is* in scope: any way to read or write a host path
  **outside** the configured `shared_paths`/`read_only_shared_paths` from
  inside a container, or any way to bypass the read-only flag on a share
  marked read-only.
- **The guest fetches images from the internet.** `docker pull` inside
  the guest talks to whatever registry the image reference names, exactly
  as it would on any other Docker host. Registry/image supply-chain
  concerns (a malicious image doing something bad once running) are
  Docker's own threat model, inherited unmodified — see "Out of scope"
  below.
- **The guest asset supply chain** (`scripts/fetch-guest-assets.sh`,
  every `dist/*/PROVENANCE.txt`) fetches third-party binaries — kernel,
  Alpine rootfs, Docker engine, k3s, cri-dockerd — over HTTPS and verifies
  them against pinned hashes before use. A way to make that verification
  pass for tampered content, or a way to make the script install
  something un-pinned, is in scope.

### In scope

- Anything that lets a process **other than the one running as your
  user** reach `docker.sock`, the daemon control socket
  (`morbstackd.sock`), or influence VM configuration.
- A guest escape, or anything that weakens the isolation the guest
  kernel's own namespaces/cgroups/seccomp provide beyond what upstream
  Docker on Linux already provides (see "Out of scope" — Morbstack
  explicitly does not claim to strengthen this).
- A way to read or write host files outside the configured
  `shared_paths`, or to defeat `read_only_shared_paths`.
- Privilege escalation via `morb`, `morbstackd`, or `morbinit` — for
  example, a way to get `morbstackd` (which itself is not privileged
  beyond the virtualization entitlement) to do something on your behalf
  that requires more privilege than you have.
- Supply-chain issues in `scripts/fetch-guest-assets.sh` or the
  provenance/verification chain it implements.
- Anything that lets `morb rosetta install` or any other command bypass
  its own documented confirmation step and take an irreversible or
  licensed action without the person at the keyboard agreeing to it (see
  [`docs/amd64.md`](docs/amd64.md) "There is no `--force`").

### Out of scope

- **Containers are not a security boundary against each other, or against
  the guest.** This is upstream Docker/Linux's own isolation model
  (namespaces + cgroups + seccomp, not hypervisor-grade isolation between
  containers) and Morbstack deliberately does not change it — see
  "The load-bearing decision" in
  [`docs/architecture.md`](docs/architecture.md). A finding that a
  container can affect another container, or the guest, in ways that are
  already true of plain Docker Engine on Linux is not a Morbstack
  vulnerability; report it upstream instead.
- **Known, documented gaps** in [`docs/parity.md`](docs/parity.md) and
  the README's "What doesn't work yet" section — for example, the
  behavioral difference where `docker run -p` on an already-bound host
  port succeeds instead of failing synchronously (parity.md #27). These
  are tracked functionality gaps, not undisclosed vulnerabilities.
- **A malicious container image doing what it was designed to do once
  running** (cryptominers, malware, etc.) — that's a supply-chain/registry
  trust question inherent to running any container from any Docker host,
  not something Morbstack introduces or can fix.
- **Denial of service via resource exhaustion inside the guest you
  control** (e.g. filling the data disk, as exercised deliberately in
  `docs/parity.md` #26) — the guest is yours; making it unusable to
  yourself isn't a security boundary violation.
- **Rosetta itself.** Morbstack exposes Rosetta for Linux to the guest but
  does not implement or audit Rosetta's translation correctness; issues in
  Rosetta itself belong to Apple.

## No independent audit yet

Morbstack has not had an independent security audit. `docs/roadmap.md`
schedules one before 1.0 ("Independent security audit completed and
findings addressed"). Until then, treat Morbstack the way you'd treat any
pre-release software with root-equivalent local privilege: appropriate for
development use on a machine you control, not yet something to point at
data or environments where a host compromise would be catastrophic.
