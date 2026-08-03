# Morbstack Functional Audit — does it actually do things?

**Date:** 2026-08-03
**Bundle:** `dist/Morbstack.app`, built 14:54 from `8190f54`
**Branch:** `code/native-content-continuation`
**Method:** every action performed in the app or via `morb`/`docker`, then **independently
verified** with the other. Isolated `DOCKER_CONFIG`; `DOCKER_HOST` pointed at
`unix:///Users/allie/.morbstack/run/docker.sock`. `~/.docker` never modified.

---

## 0. THE MOST IMPORTANT SECTION: what "tested" means here

Read this before believing any result below. Three different things can be true of a
finding, and conflating them is how this project has previously fooled itself.

### 0.1 The running daemon was six hours stale for the first half of this audit

The brief said a `morbstackd --foreground` (PID 20575) was running "from
`dist/Morbstack.app`". That was true **by path and false by content**:

```
PID 20575 (running)     started Aug 3 04:19    text image mapped: 3,654,240 bytes
dist/…/MacOS/morbstackd built   Aug 3 14:54    file on disk:      5,353,856 bytes
```

Same path, different inode — macOS keeps the old inode mapped after the file is replaced.
PID 20575 predated the bundle by ten hours and predated commit `435d09f` (the bind-mount
fix) by six. **Every host-side result measured before 15:27 was against pre-fix code.**

Remediation: killed 20575 by exact PID, cold-started via `morb start`, verified the new
daemon (PID 32203) maps the current 5,353,856-byte image, and **re-ran the affected tests**.
Results below are post-restart unless explicitly noted.

**Lesson for future audits:** verify the *inode/size* of a running daemon, not its path.

### 0.2 The guest image is stale — and the shipped bundle ships it that way

```
running initrd.img   built Aug 2 19:46   sha256 e82ff43771bf…
bundle  initrd.img   (copied Aug 3 14:54) sha256 e82ff43771bf…   ← BYTE-IDENTICAL
```

Rebuilding the app does **not** refresh the guest. **21 commits touching `guest/` landed
after the running initrd was built**, including every feature the handoff doc flagged:

| Commit | Feature | Consequence |
|---|---|---|
| `06bf81d`, `103ab2d`, `8e3b82c` | publish-all (`docker run -P`) | `-P` not present in running guest |
| `ce02ae4` | host.docker.internal / gateway.docker.internal DNS | parity #18/#19 still fail |
| `435d09f` | macOS bind-mount alias guard (`/tmp`, `/var`, `/etc`) | `/tmp` still broken |
| `5f94d3a` | UDP published ports over vsock | untested |
| `2f8272f`, `bc94e78` | host networking bridged to Mac ports | parity #20 unchanged |
| `53f6d4a`, `acd0925` | verified grow-only disk transaction | `disk grow` unexercised |
| `3115ff0`, `64b89f6`, `5f5c076` | live-share / FSEvents bridge | inotify still dead |

**This is not merely a testing artifact.** The bundle a user installs today contains this
same guest image. So these behaviours are **live defects as shipped**, even though source
contains fixes. The correct statement is: *"fixed in source, not in any shipped artifact,
and unverifiable until someone rebuilds the guest image."* No guest image was rebuilt
during this audit (explicitly out of scope).

### 0.3 Three-way classification used throughout

- **PROVABLE NOW** — measured against current host daemon + shipped guest. Trustworthy.
- **GUEST-BLOCKED** — source fix exists; cannot take effect without a guest rebuild. A FAIL
  here is a fact about the shipped bundle, **not** evidence the code is wrong.
- **OPEN** — no fix in source; genuinely unresolved.

---

## 1. Engine lifecycle — **PASS** (PROVABLE NOW)

| Step | Command | Result |
|---|---|---|
| Stop VM | `morb stop` | `[--] stop: stopped` in **12.7s** |
| Cold start | `morb start` | `[ok] start: running` in **3.0s** |
| Verify | `morb status` | vm running / guest control ready / docker ready |
| Engine identity | `docker version` | Server **29.7.1**, API 1.55, linux/arm64, containerd v2.3.3, runc 1.4.3 |
| Guest | `docker info` | Alpine Linux v3.24, kernel **6.18.15**, overlay2, cgroup v2 |

**A 3.0-second cold boot to a ready dockerd is genuinely excellent** and is the single most
impressive number in this audit. Data persisted across the restart (all containers, images
and volumes survived).

Not tested: engine start/stop **from the app UI** (the Engine menu was not exercised).

## 2. Live updates — **PASS** (PROVABLE NOW)

`docker run -d --name auditnginx -p 18099:80 nginx:alpine` from the CLI, app sitting on
Containers, untouched:

- Row appeared with a green running dot in **under 2 seconds**, no manual refresh.
- Header moved `0 running · 4 total` → `1 running · 5 total`; sidebar badge tracked it.
- **Selection was preserved** — it stayed on the previously selected container and did not
  jump to the new row. This is the hard part and it is done correctly.
- Stopping from the UI updated the row to `Exited (137) Less than a second ago` and re-sorted
  it (running-first, then alphabetical) immediately.

**Caveat — see UI-020:** steady-state uptime strings go stale. Rows read "Up 23 seconds"
while `docker ps` said "Up About a minute" at the same moment. Event-driven updates are
excellent; there is no periodic re-render between events.

## 3. Container actions from the UI — **PASS** (PROVABLE NOW)

| Action | How | CLI verification |
|---|---|---|
| Stop | Right-click → Stop | `docker inspect -f '{{.State.Status}}'` polled 1Hz: `running`×5 → `exited` at +5s. `Exited (137)` — SIGKILL after the shell ignored SIGTERM, i.e. correct Docker semantics. |
| Start | Toolbar ▶ (tooltip read **"Start auditburn"**) | `docker ps` → `Up 6 seconds` |
| Restart / Remove | — | **NOT TESTED** |

Context menu is a clean native `NSMenu`: Stop / Restart / Pause — Copy Name / Copy Container
ID — Remove…

## 4. Logs — **PARTIAL** (PROVABLE NOW)

- Live tail rendered, 68 lines, with a line count and an in-content "Filter lines" field.
- **The filter field is in the content, not the toolbar** — which is very likely why the
  reported two-`.searchable` SIGTRAP no longer occurs.
- **FAIL (UI-009):** every nginx line rendered red with a warning triangle, *including*
  `[notice]` lines. Colour is driven by stream (stderr), not severity or ANSI codes.
- **NOT TESTED:** follow/tail toggles, the filter field itself (synthetic typing was blocked
  all session), real ANSI colour rendering, and scroll smoothness on a ~10k-line container.

## 5. Stats — **PASS**, including the specific known bug (PROVABLE NOW)

The known past defect (first sample = lifetime average because `precpu` was zero-filled)
**does not reproduce**. Against `alpine sh -c 'while true; do :; done'` (one core saturated):

| | App | `docker stats` | Verdict |
|---|---|---|---|
| **First sample** | **100.6%** | **100.14%** | **match — bug fixed** |
| After 34s (18 readings) | 99.9% | 99.93% | match |
| Memory | 1.2 MB | 1.105 MiB (=1.159 MB) | match |
| Limit | 268.4 MB | 256 MiB (=268.4 MB) | match |
| Percent | 0.4% | 0.43% | match |

Real Swift Charts, real data. Chart axis defects logged as UI-007/UI-008. Stopping the
container correctly swapped in a `ContentUnavailableView` ("No Live Statistics — This
container is not running. Its resource history is available only while it runs.").

## 6. Inspect — **PASS** (PROVABLE NOW)

Real `docker inspect` JSON with a scoped "Search document" field. Content matched the engine.
Long values clip at the pane edge (UI-013). Search-within-document **not exercised** (typing
blocked).

## 7. Ports — **PARTIAL** (PROVABLE NOW)

- `curl http://localhost:18099/` → **HTTP 200 in 24ms**. Publishing genuinely works.
- Overview tab renders the mapping and an **"Open"** link.
- **FAIL (UI-002):** the port renders as **`0.0.0.0:18,099`** — thousands separator in a port
  number.
- **NOT TESTED:** clicking "Open" (browser access was denied), so whether the link carries the
  correct URL — or the comma — is **unknown**. This is a priority for the next pass.

## 8. Images — **NOT TESTED**

Pull-from-app with progress, remove, and the in-use-image error path were **not exercised**.
The route was only observed at narrow width (UI-017). Listing was correct (15 images, 1.38 GB,
matching `docker images`).

## 9. Disk — **PARTIAL** (PROVABLE NOW)

| Figure | App | Reality | Verdict |
|---|---|---|---|
| In use | 1.34 GB | `docker system df` 1.342GB | **match** |
| Reclaimable | **1.31 GB** | **1.21 GB** (1.21GB + 2.186kB + 0 + 1.549kB) | **~100 MB / 8% overstatement** (UI-021) |
| VM disk apparent | 68.72 GB | 64 GiB = 68.72 GB | match |
| VM disk on APFS | 3.65 GB | `du` 3.4G = 3.65 GB | match |
| Allocated | 5.3% | 3.65/68.72 = 5.3% | match |

The sparse-file explanation ("This sparse file reserves 68.72 GB but currently uses 3.6 GB on
APFS") is honest and genuinely useful.

**Prune from the app was NOT run**, so the "does the preview match what was actually deleted"
question — the most important one for this route — is **unanswered**.

## 10. Real multi-service stack — **PASS**, and the strongest result in this audit

Reproduction fixture, verbatim. Place at `/private/tmp/morbaudit-stack/compose.yaml`
(**not** `/tmp/...` — see §12) with `site/index.html`, `app/server.py`, `app/Dockerfile`
and `pg_password.txt` alongside.

```yaml
name: morbaudit

services:
  web:
    image: nginx:alpine
    ports: ["18100:80"]
    volumes: ["./site:/usr/share/nginx/html:ro"]
    depends_on: { api: { condition: service_healthy } }
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost/"]
      interval: 5s
      timeout: 3s
      retries: 5

  api:
    build: ./app
    image: morbaudit-api:v1
    ports: ["18101:8000"]
    environment:
      APP_GREETING: hello-from-compose
      PGHOST: db
      SHELL_SOURCED_SECRET: ${AUDIT_HOST_SECRET}
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request;urllib.request.urlopen('http://localhost:8000/health')"]
      interval: 5s
      timeout: 3s
      retries: 10
    depends_on: { db: { condition: service_healthy } }

  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: morb
      POSTGRES_DB: morbaudit
      POSTGRES_PASSWORD_FILE: /run/secrets/pg_password
    secrets: [pg_password]
    volumes: ["dbdata:/var/lib/postgresql/data"]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U morb -d morbaudit"]
      interval: 5s
      timeout: 3s
      retries: 10

volumes: { dbdata: }
secrets:
  pg_password:
    file: ./pg_password.txt
```

`docker compose up -d --build` → **12.9 s total**, including a BuildKit image build.

| Assertion | Evidence |
|---|---|
| Healthcheck-chained `depends_on` | `db Healthy` → `api Starting/Healthy` → `web Started`, in order |
| All services healthy | `morbaudit-{api,db,web}-1  Up … (healthy)` |
| Bind mount served | `curl :18100` → `<h1>bind-mount-v1</h1>` (host file) |
| `environment:` delivered | `curl :18101` → `{"greeting": "hello-from-compose", "db": "db"}` |
| Named volume | `morbaudit_dbdata` created |
| **`secrets:` genuinely functional** | `psql` inside db authenticated via `/run/secrets/pg_password` and returned a row |
| Survives VM restart | full stack came back up cleanly after `morb stop`/`morb start` |

Reproduced twice, including once after a full engine restart.

**NOT TESTED:** the app's **Stacks route** against this project — grouping, per-stack actions,
the Compose source inspector, and the env/secret boundary claims in
`docs/compose-environment-secrets-inspection.md`. The Stacks route was only ever seen showing
fixture data. **The claims in that document remain entirely unverified.**

## 11. Bind mounts — **PASS under `/Users`**, **FAIL elsewhere** (see §12)

Under `/Users` (the documented, supported root), all bidirectional:

| Test | Result |
|---|---|
| Container reads host file | `host-wrote-this-v1` |
| Container writes, host reads | `container-wrote-this-v1` |
| Host edits while container running, container re-reads | `host-edit-v2` — **fresh content, no staleness** |
| Symlinked directory **inside** `/Users` (dotfile-style) | **works** — resolved correctly |

**inotify — INCONCLUSIVE, not FAIL.** My `inotifyd` harness produced zero events even in the
**control** case (edit made inside the container on a native, non-bind directory), so the
harness is broken, not necessarily the feature. Parity #10's prior FAIL is **neither confirmed
nor refuted here**. It is also GUEST-BLOCKED (`3115ff0`, `64b89f6`, `5f5c076`).

## 12. Bind-mount path resolution — **the most serious defect found**

**Classification: GUEST-BLOCKED, but live in the shipped bundle.**

`morb shares` exposes `/Users`, `/Volumes`, `/private/tmp`, "mounted at the same absolute path
inside the guest". macOS `/tmp`, `/var`, `/etc` are symlinks to `private/…`. The mount source
is passed to the engine **unresolved** and interpreted as a *guest* absolute path.

Measured against the **current** daemon (PID 32203) and the **shipped** guest:

| Mount source | Result | Failure mode |
|---|---|---|
| `-v /tmp/dir:/data` | empty directory | **silent — no error, no warning** |
| `-v /tmp/file.txt:/f` | `invalid mount config … bind source path does not exist` | hard error |
| `-v /var/log:/probe` | empty | **silent** |
| `-v /etc:/probe` | **the Linux VM's `/etc`** (`alpine-release`, `apk`, `busybox-paths.d`) | **silent, and actively wrong data** |
| `-v /etc/hosts:/probe` | `127.0.0.1 localhost localhost.localdomain` — **the VM's hosts file, not the Mac's** | **silent, and actively wrong data** |
| `-v /private/tmp/…` | correct | — |
| `-v /Users/…` | correct | — |

**The worst variant is not the empty directory — it is guest-content substitution.** A user
mounting `/etc/hosts` gets a plausible-looking file that is silently the wrong machine's.

Docker also **creates the missing source inside the VM**: after my `/tmp` attempts, the VM's
own `/tmp` contained a `morbaudit-stack` directory that had never existed there.

### The fix exists in source and is well designed — it just isn't in any shipped artifact

`435d09f "Guard macOS bind mount aliases"` is a correct, fail-closed, two-sided fix:
- **guest** (`guest/morbinit/src/mounts.rs`): `alias_tmp_to_shared_private_tmp()` binds the
  guest's literal `/tmp` onto the `/private/tmp` VirtioFS root and reports
  `info.tmp_alias_mounted: true`.
- **host** (`mac/Sources/MorbstackKit/DockerBindMountPreflight.swift`): admits a bare `/tmp`
  source **only after** the guest confirms that fact; an older guest "is not guessed to be
  safe".
- bare `/var` and `/etc` are **explicitly rejected**, directing users to `/private/…`.

**But with the shipped guest the rejection does not happen** — I confirmed the guest never
emits `tmp_alias_mounted` (absent from all logs) and the daemon logs no preflight decision at
all. Bad mounts pass through silently.

**Do not close this as fixed until it is re-tested against a rebuilt guest image.**

## 13. Failure handling — **NOT TESTED**

Stopping the engine while the app sits on a busy screen — graceful message vs.
hang/spin/stale-data — was **not exercised**. This was a named brief item and it is a gap.

---

## 14. THE UI CLAIMED ONE THING AND REALITY WAS ANOTHER

Ordered by seriousness. This is the defect class that matters most.

1. **Fixture mode is indistinguishable from live, and the footer states a falsehood.**
   A `--tour-fixtures` window showed 11 fabricated containers (`shopfront-postgres-1` "Up 12
   days (healthy)", `legacy-jenkins` "Up 9 days (Paused)", `registry-mirror` "Restarting (1)
   (unhealthy)") with consistent badges and stack counts, while **hiding all 10 real
   containers** — and the sidebar footer read **"Engine running"**, which fixture mode never
   even checks. `docker inspect` confirmed none of the 11 exist. **This is the single worst
   UI-lies-about-reality discrepancy in the audit.** It fooled a dedicated auditor for ~60
   seconds; a reviewer looking at a screenshot in a PR cannot catch it at all, and this
   project has already been burned by exactly this class of error with MorbShots renders.
   (UI-001)

2. **`/etc` and `/etc/hosts` bind mounts silently serve the Linux VM's files as if they were
   the Mac's.** No error, no warning, plausible-looking content. (§12)

3. **`/tmp` and `/var` bind mounts silently produce empty directories.** The container sees an
   empty dir and the user concludes their build is broken. (§12)

4. **A port is displayed as `18,099`.** Wrong on its face. (UI-002)

5. **Container uptime freezes.** "Up 23 seconds" displayed while `docker ps` said "Up About a
   minute" at the same instant. (UI-020)

6. **Disk overstates reclaimable space by ~8%** (1.31 GB vs the engine's 1.21 GB). A prune
   driven by that number will under-deliver. (UI-021)

7. **`morb status` double-counts published ports** — "published ports (8…)" for 4 actual
   ports, each printed twice (dual-stack listeners not deduplicated). (UI-014)

---

## 15. FINDINGS INVALIDATED OR CONSTRAINED BY THE STALE GUEST IMAGE

Every FAIL here is a fact about **the shipped bundle**, not evidence the source is wrong.
None can be resolved without a guest-image rebuild.

| Finding | Observed | Source fix | Status |
|---|---|---|---|
| `/tmp`, `/var`, `/etc` bind mounts | silent empty / wrong data | `435d09f` (two-sided, fail-closed) | **GUEST-BLOCKED** — retest after rebuild |
| `docker run -P` | `could not reach the host publish-all allocator: vsock connect to port 2379 failed: Connection reset by peer` | `06bf81d`, `103ab2d`, `8e3b82c` | **GUEST-BLOCKED**. Error is well-explained and names the missing guest component precisely — good diagnostics. |
| `host.docker.internal` | UNRESOLVED | `ce02ae4` | **GUEST-BLOCKED** (parity #18) |
| `gateway.docker.internal` | UNRESOLVED | `ce02ae4` | **GUEST-BLOCKED** (parity #19) |
| inotify hot reload | inconclusive (broken harness) | `3115ff0`, `64b89f6`, `5f5c076` | **GUEST-BLOCKED + untested** (parity #10) |
| UDP published ports | not tested | `5f94d3a` | **GUEST-BLOCKED** |
| `morb disk grow` | not tested | `53f6d4a`, `acd0925` | **GUEST-BLOCKED** |
| `--network host` | not re-tested | `2f8272f`, `bc94e78` | **GUEST-BLOCKED** (parity #20) |

---

## 16. Part 3 — CLI and Docker parity

### 16.1 `morb` — **PASS, and a highlight of the project**

Every subcommand exercised returned correct output with correct exit codes:

| Command | Result | Exit |
|---|---|---|
| `morb status` | full VM/docker/socket/cpu/memory state + published ports | 0 |
| `morb shares` | 3 paths + honest caveat about unshared roots | 0 |
| `morb rosetta` | active, host installed, binfmt registered | 0 |
| `morb disk status` | 64 GiB configured, `matches-configuration` | 0 |
| `morb context status` | `morbstack` **not registered**; correctly reports `DOCKER_HOST` precedence | 0 |
| `morb service status` | not-found, with an actionable diagnostic | 0 |
| `morb k8s status` | stopped, installed-in-guest true, 0/0 nodes | 0 |
| `morb ports check --tcp 18099` (busy) | `[!!] another process currently owns …` | **2** |
| `morb ports check --tcp 59999` (free) | `[ok] available now; this check does not reserve the port` | 0 |
| `morb boguscommand` | `unknown command` + usage | **2** |
| `morb version` | morb + morbstackd both `0.1.0-m0` | 0 |

**The help text is honest, and unusually so.** It states limits rather than hiding them:
*"snapshots, not reservations"*, *"never reserves or starts the daemon"*, *"refuses to replace
another explicit default without --force (never stomps)"*, *"does not open a shell yet"*,
*"Legacy: …(prefer install-cli)"*. `morb debug` volunteers: *"A toolbox shell for a distroless
container is not implemented. Morbstack does not equate a regular `docker exec` with a
toolbox…"*. **This is the opposite of LLM slop and should be held up as the house style.**

Defects: `morb status` port double-listing (UI-014); one misaligned help column
(`uninstall-cli` overruns the 12-char gutter, `install-cli-plugins` wraps).

### 16.2 Bundled toolchain — parity #13 **FIXED**

`Contents/Resources/host-bin/` ships `docker` 29.7.1 (client matches server), `docker-compose`
**v5.3.1**, `docker-buildx` **v0.36.0**, with `TOOLCHAIN.plist` recording `sha256` and
`source_sha256` per tool plus an 11 KB `PROVENANCE.txt`. A real BuildKit build ran end to end.
Prior parity #13 ("no buildx plugin out of the box") is **resolved**.

**Caveat:** plugins resolve from `$DOCKER_CONFIG/cli-plugins`. Anyone isolating `DOCKER_CONFIG`
loses `docker compose` entirely until the bundled plugins are linked in. Worth confirming
`morb install-cli` covers this.

### 16.3 Docker Desktop coexistence — honest, but not drop-in

- With an isolated `DOCKER_CONFIG`, `docker context ls` shows only `default`; the user's real
  `desktop-linux` context lives in `~/.docker` (untouched).
- `morb context status`: **`morbstack` context is not registered** out of the box.
- The conventional discovery socket `~/.docker/run/docker.sock` is **already owned by Docker
  Desktop**, and Morbstack **preserves it rather than stomping it** — correct and safe, and it
  refuses to touch system-owned `/var/run/docker.sock`.
- **Consequence:** on a machine with Docker Desktop installed, zero-config discovery still
  finds Docker Desktop. A user must explicitly run `morb install-cli` / `morb context create`.
  Honest and non-destructive, but **not drop-in** (parity #17 remains FAIL).

### 16.4 Parity re-run vs `docs/parity.md` (prior: 20 PASS / 3 PARTIAL / 6 FAIL @ `081aa29`)

| # | Check | Prior | Now | Note |
|---|---|---|---|---|
| 1–4 | version / info / core CLI / df+prune | PASS | **PASS** | server 29.7.1, cold boot 3.0s |
| 5 | compose multi-service + healthchecks | PASS | **PASS** | §10, stronger fixture |
| 7 | compose build | PASS | **PASS** | now BuildKit, not classic |
| 8 | bind mount fresh content | PASS | **PASS** | under `/Users` |
| 9 | `/tmp` bind source | FAIL | **FAIL** | **not fixed as shipped** — GUEST-BLOCKED (§12) |
| 10 | inotify hot reload | FAIL | **INCONCLUSIVE** | my harness was broken; GUEST-BLOCKED |
| 13 | buildx out of the box | FAIL | **PASS** | **changed** — §16.2 |
| 17 | zero-config socket discovery | FAIL | **FAIL** | unchanged; Docker Desktop owns the socket (§16.3) |
| 18 | `host.docker.internal` | FAIL | **FAIL** | GUEST-BLOCKED |
| 19 | `gateway.docker.internal` | FAIL | **FAIL** | GUEST-BLOCKED |
| 23 | `docker context` integration | PASS | **PASS** | context not auto-created; creation path not re-run |
| 27 | port already bound on Mac | PARTIAL | **PARTIAL** | unchanged — `docker run -p 19999:80` returned **rc=0 with no error** while the port was held |
| 28 | nonexistent image | PASS | **PASS** | proper `pull access denied` error |
| 29 | OOM | PASS | **PASS** | exit **137** |
| 6, 11, 12, 14–16, 20–22, 24–26 | — | — | **NOT RE-RUN** | out of budget |
| — | `docker run -P` | (new) | **FAIL** | GUEST-BLOCKED, well-explained error |
| 21 | DinD via socket bind | PASS | **INCONCLUSIVE** | image pull did not complete in time |

**Net change: +1 genuine improvement (#13 buildx). No regressions introduced. #9 was believed
fixed and is not — as shipped.**

---

## 17. Cleanup

Docker state was diffed against a baseline captured before any test work:

```
containers: MATCH baseline
volumes:    MATCH baseline
images:     MATCH baseline
networks:   3 present; default bridge has a new ID after the VM restart (not a leak)
```

All created resources removed: containers `auditnginx`, `auditburn`, `auditbind`, `auditP`,
`auditP2`, `auditport`; the whole `morbaudit` compose project (3 containers, network, volume);
images `morbaudit-api:v1`, `postgres:16-alpine`. Pre-existing state (`api`, `cache`, `lonely`,
`web`, `shopdemo_data`, all 15 baseline images) untouched. `~/.docker` never modified.

**Could not clean up** — `rm -rf` was refused by the permission system:
- `/tmp/morbaudit-dockercfg/`, `/tmp/morbaudit-env.sh`, `/tmp/morbaudit-baseline/`,
  `/tmp/morbaudit-now-*.txt`
- `/private/tmp/morbaudit-stack/` (the compose fixture — arguably worth keeping, see §10)
- `/Users/allie/Develop/morbstack/artifacts/audit/{bindtest,linkdir,realdir}/`

Final verified state — matches the pre-audit baseline exactly:

```
containers: 4  (api, cache, lonely, web — all pre-existing)
volumes:    1  (shopdemo_data — pre-existing)
images:     15 (baseline count)
```

**Daemon:** the stale PID 20575 was deliberately killed and replaced by PID 32203
(`morb start`), running the current bundle binary. The engine is **left running**, as it was
found. The Morbstack app was stopped via `scripts/ui-tour.sh --stop`; no `MorbstackApp`
process remains.
