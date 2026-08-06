# Releasing Morbstack

How to cut a Morbstack build and what the resulting `.dmg` is — and is not.
This is the current, ad-hoc-signed release path. Developer ID signing and
notarization are separate, blocked tickets (REL-2, SP-9) and are **not**
implemented by anything described here.

## Quick start

```sh
scripts/release.sh
```

This is the same sequence CI runs (`.github/workflows/release.yml`), and it
is meant to be genuinely runnable on a contributor's own Mac, not a
CI-only path — see "Why this has to run locally" below.

It does, in order:

1. `scripts/fetch-guest-assets.sh` — fetches and sha256-verifies every
   pinned third-party asset (kernel, upstream Docker engine, Alpine
   rootfs, fsutils, the host Docker CLI + Compose + Buildx, k3s +
   cri-dockerd). Idempotent: a second run just re-verifies hashes.
2. `mise run guest-image` — cross-compiles `morbinit` for
   `aarch64-unknown-linux-musl` and assembles the bootable initramfs.
3. `mise run app` — builds the three release binaries, assembles
   `dist/Morbstack.app`, and signs it inside-out, ad-hoc. This step
   already ends with a hard check that `morbstackd` did not lose
   `com.apple.security.virtualization` during signing (CLAUDE.md §1.1)
   — that check is not duplicated here.
4. `scripts/make-dmg.sh` — packages `dist/Morbstack.app` into a
   drag-to-Applications DMG.
5. An independent verification pass: mounts the DMG **read-only** and
   re-checks the entitlement against the bytes actually inside it, not
   against `dist/Morbstack.app` before packaging. Fails loudly (exit
   non-zero) if the entitlement did not survive the DMG round-trip.

The output is `dist/Morbstack-<version>.dmg`, where `<version>` comes from
`mac/Sources/MorbstackKit/Version.swift`.

### Reusing an existing `~/.morbstack`

By default `scripts/release.sh` fetches and builds into its own scratch
`MORBSTACK_HOME` (`dist/.release-home`, already excluded by `.gitignore`)
so a release build never depends on, or disturbs, a real `~/.morbstack` a
running daemon might own. If you already have a normal dev checkout with
kernel/k8s assets fetched, point the script at it instead to skip
re-downloading them:

```sh
MORBSTACK_HOME=~/.morbstack scripts/release.sh
```

Do not do this while a `morbstackd` you care about is running against that
same `MORBSTACK_HOME` — the fetch and guest-image steps write into
`$MORBSTACK_HOME/data/kernel` and `$MORBSTACK_HOME/data/k8s`.

See `scripts/release.sh`'s own header comment for the full list of env
overrides (`MORBSTACK_SIGN_IDENTITY`, `SKIP_FETCH`, `DMG_PATH`).

## The guest image ships inside the app, not fetched on first launch

A release build assembled by `mise run app` alone (without a preceding
`mise run guest-image`) is incomplete: the app bundle would have no
bootable guest, and §1.8's "no placeholder states" rule means that is not
an acceptable shipped state. `scripts/release.sh` resolves this by always
running `mise run guest-image` before `mise run app`, and the two are
already wired together:

- `mise run guest-image` writes the kernel and initramfs to
  `$MORBSTACK_HOME/data/kernel/{vmlinux,initrd.img}`, and
  `scripts/fetch-guest-assets.sh --k8s-only` (part of the full fetch in
  step 1 above) writes `k3s` and `cri-dockerd` to
  `$MORBSTACK_HOME/data/k8s/`.
- `mise run app` calls `scripts/package-runtime-artifacts.sh`, which
  copies those exact four files into
  `Contents/Resources/runtime/<version>/` inside the bundle, alongside a
  sha256 manifest, **before** the outer bundle is signed. So the runtime
  payload is sealed by the same code signature that covers the rest of
  the app — it travels inside the DMG, not as a post-install download.
- On first launch, `morbstackd` calls
  `RuntimeArtifactStore.installBundledRuntimeIfPresent()`
  (`mac/Sources/MorbstackKit/RuntimeArtifacts.swift`,
  `Daemon.swift:188`), which validates the app's own code signature,
  re-verifies every artifact's hash against the sealed manifest, and
  copies them into the user's mutable runtime data area
  (`MorbPaths.runtimeArtifactsDirectory`) before it will boot a VM with
  them. A signature or hash mismatch is a hard failure, not a silent
  fallback to whatever bytes happen to be on disk already.

So: **the answer to "does a fresh Mac get a bootable guest from this DMG"
is yes, staged inside the bundle** — as long as it can run the app at all
(see the entitlement section below for the actual gate on that).

## What "ad-hoc signed" means for this DMG

`mise-tasks/app` signs every binary inside `Morbstack.app` — including
`morbstackd` — with `codesign --sign -`: the ad-hoc identity, not a
Developer ID certificate. This is deliberate for local development
(CLAUDE.md §1.1), and `scripts/release.sh` does not change it — REL-2/SP-9
own actually adding Developer ID signing and notarization.

**This has a real, load-bearing consequence for `morbstackd` specifically,
not just a cosmetic one:**

`com.apple.security.virtualization` is a **restricted entitlement**. Per
Apple's own technote on code signing and provisioning profiles:

> "In contrast, restricted entitlements must be authorized by a
> provisioning profile. [...] Some macOS products, like daemons and
> command-line tools, ship as a standalone executable. A standalone
> executable can't claim a restricted entitlement because there's no
> place to embed the provisioning profile that authorizes that claim."
> — [TN3125: Inside Code Signing: Provisioning Profiles](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)

Ad-hoc signing (`codesign --sign -`) produces no provisioning profile at
all — there is nothing for AMFI to check the entitlement claim against
except the local machine's own trust of code it just built. That local
trust does not travel. A developer hit exactly this on the Apple Developer
Forums: a CLI ad-hoc signed and carrying
`com.apple.security.virtualization` (confirmed present via
`codesign -d --entitlements -`) worked "like a charm" on the machine that
built it, then failed on a second Mac with:

> `Failed to validate the virtual machine configuration. [...] The
> process doesn't have the "com.apple.security.virtualization"
> entitlement.`

— resolved only once the developer obtained an Apple Developer account
and signed with it instead of ad hoc.
([Apple Developer Forums, "Virtualization entitlement"](https://developer.apple.com/forums/thread/698220))

**Consequence for a DMG produced by `scripts/release.sh` today:**

| | Same Mac that built it | A different Mac |
| --- | --- | --- |
| App launches, UI works | yes | yes, after clearing Gatekeeper's "unidentified developer" quarantine (see below) |
| `morb`/CLI, host Docker context | yes | yes |
| `morbstackd` can open a `VZVirtualMachine` and boot the guest | yes | **no** |

An ad-hoc-signed `morbstackd` copied to another Mac will fail to boot the
VM with the same "doesn't have the entitlement" error quoted above, even
though `codesign -d --entitlements -` on that same binary still reports
the entitlement as present — the bytes are unchanged, but AMFI on the
second machine has no provisioning-profile chain to accept the claim.
**This means today's DMG is only really useful on the machine that built
it.** Getting a DMG that boots VMs on other Macs requires Developer ID
signing (an Apple Developer Program membership, a Developer ID Application
certificate, and re-signing the bundle with it in place of `-`) — tracked
by REL-2/SP-9, not implemented here.

### Gatekeeper, separately from the entitlement problem above

Even setting the entitlement issue aside, an ad-hoc-signed, non-notarized
app downloaded onto another Mac is quarantined by Gatekeeper the moment it
crosses a network boundary (Safari, Mail, `curl` to a file later opened by
Finder, etc. all set `com.apple.quarantine`). The user sees "\`Morbstack\`
can't be opened because it is from an unidentified developer," and must
explicitly override that from **System Settings → Privacy & Security**
before the app will launch at all. This is standard macOS behavior for any
non-notarized download, not something specific to this project — see
Apple's own guidance for what a user does with such a download:
[Open a Mac app from an unidentified developer](https://support.apple.com/guide/mac-help/mh40616/mac).
This project does not attempt to reproduce that procedure here; direct
anyone hitting it at Apple's page, which is the canonical, currently
accurate source.

Notarization (which would remove the Gatekeeper prompt) and Developer ID
signing (which would fix the entitlement problem above) are two different
mechanisms solving two different problems, and this project has neither
yet. Both are tracked by REL-2/SP-9.

## Why this has to run locally, not just in CI

As of this writing, GitHub Actions on this project's account is not
accepting jobs (billing issue upstream of anything in this repo), so
`.github/workflows/release.yml` has not been exercised even once — same
caveat CLAUDE.md §5 already states for `ci.yml`. `scripts/release.sh` is
written so the release path does not wait on that: every step it runs
(`fetch-guest-assets.sh`, `mise run guest-image`, `mise run app`,
`make-dmg.sh`, the entitlement re-check) is a plain, local command with no
CI-specific behavior. The workflow just runs the same script on a
`macos-26` runner, on a `v*` tag push or by hand
(`workflow_dispatch`).

## What is proven versus unproven

**Proven** (`scripts/release.sh` run to completion, twice, directly on this
development machine while building this release path — the second run
after fixing the bug below):

- `scripts/fetch-guest-assets.sh` (all pinned assets, including the
  kernel, docker engine, k3s and cri-dockerd), `mise run guest-image`,
  `mise run app`, and `scripts/make-dmg.sh` chain together correctly end
  to end and produce a real `dist/Morbstack-0.1.0-m0.dmg` (224MB).
- The entitlement survives packaging. `scripts/release.sh`'s own step 5
  mounted the finished DMG and confirmed it; this was then independently
  re-verified by hand, outside the script, against a fresh mount of the
  same DMG: `codesign -d --entitlements -` on the mounted
  `Morbstack.app/Contents/MacOS/morbstackd` reports
  `com.apple.security.virtualization = true`, and
  `codesign --verify --deep --strict` on the mounted `Morbstack.app`
  exits 0.
- `scripts/release.sh` passes `shellcheck` (`mise run check`'s gate).
- Found and fixed a real bug in the process: `scripts/make-dmg.sh` was
  checked into git without its executable bit (mode `644`), even though
  its own header says `Usage: scripts/make-dmg.sh` — direct invocation.
  The first `scripts/release.sh` run failed at that exact step with
  `Permission denied`. Fixed with `chmod +x scripts/make-dmg.sh`, included
  in this same change; the second run completed clean.

**Unproven:**

- `.github/workflows/release.yml` has never executed (GitHub Actions is
  currently refusing to start jobs on this account — see above). Its
  steps mirror `ci.yml`'s conventions closely enough that they are
  expected to work, but "expected" is not "observed."
- Whether the *published* DMG (as opposed to the one built and verified
  on this machine) boots a VM on a second Mac. The entitlement research
  above is Apple's own documented behavior plus a directly-matching,
  independently reported case, not a live test against a second machine
  from this worktree — this worktree does not have access to one. Treat
  the "no" in the table above as well-supported, not yet independently
  reproduced by this project.
