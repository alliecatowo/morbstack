# Publishing this repository

Status: this repository has never been pushed anywhere. `git remote -v`
prints nothing, `main` has 5 commits, and there is no GitHub repo yet. This
document is the exact, ordered checklist for the human who does that —
each step says what to run and what to verify before moving to the next
one. Nothing here should be automated into a script without a person
reading the output at each step first; several of these steps are
one-way (repo creation, branch protection, the first push) and worth
getting right deliberately rather than quickly.

## 1. Decide the name

TODO(human): decide and record the final choice here before proceeding —
this document assumes the outcome below but does not make the decision
for you.

Working assumption used throughout this document and in the placeholder
URLs already committed elsewhere in this repo (`.github/ISSUE_TEMPLATE/config.yml`,
and any README badge URLs):

- **GitHub organization or user**: `morbstack` (an org, not a personal
  account — a project that wants outside contributors and a Homebrew tap
  down the line is easier to hand off, add maintainers to, and rotate
  credentials for under an org than under one person's personal account).
- **Repository name**: `morbstack`.
- **Resulting URL**: `https://github.com/morbstack/morbstack`.

If the real decision differs (a personal account, a different name, an
already-registered `morbstack` org taken by someone else), grep the repo
for the literal string `morbstack/morbstack` and update every hit — the
issue template contact links are the ones known to need it; check README
badges and any release/site tooling other workers have added since.

## 2. Create the repository

From this local checkout, with the `gh` CLI authenticated as an owner of
the `morbstack` org (or your personal account, if that's the final
decision from step 1):

```sh
gh repo create morbstack/morbstack \
  --public \
  --description "The Docker Desktop replacement for macOS: unmodified upstream dockerd in a fast, native SwiftUI shell. Free forever, Apache-2.0." \
  --homepage "https://morbstack.dev" \
  --source=. \
  --remote=origin
```

- `--public`: this is an open-source project from day one; there is no
  private-then-open transition planned.
- `--source=.` with `--remote=origin` creates the GitHub repo *and* wires
  the local checkout's `origin` remote in one step, rather than creating
  the repo separately and adding the remote by hand — one fewer place to
  typo a URL.
- `--homepage`: only set this once the site (being built separately under
  `site/`, per this project's worker split) is actually deployed and has
  a real URL. Until then, omit `--homepage` or leave it pointing at the
  repo itself; do not publish a homepage link that 404s on day one.

This does **not** push anything yet — `gh repo create --source=. --remote=origin`
creates an empty remote repo and adds the remote; it does not push `main`
for you. That's step 6, deliberately separate, so branch protection (step
4) and repo settings (step 3) can be configured against an empty repo
before any commit or workflow run touches it.

## 3. Repository settings

In `Settings` (or via `gh api`/`gh repo edit`) before the first push:

- **Features**: enable Issues (on by default) and **Discussions** (off by
  default — turn it on; `.github/ISSUE_TEMPLATE/config.yml`'s
  "Questions and discussion" contact link assumes it exists). Leave Wiki
  off; documentation lives in `docs/` under version control, not a wiki
  that drifts from it.
  ```sh
  gh repo edit morbstack/morbstack --enable-discussions
  ```
- **Topics**: add enough that the repo is findable and correctly
  categorized —
  ```sh
  gh repo edit morbstack/morbstack --add-topic docker --add-topic docker-desktop \
    --add-topic macos --add-topic virtualization --add-topic swift \
    --add-topic swiftui --add-topic containers --add-topic kubernetes
  ```
- **Merge settings**: this project's `CONTRIBUTING.md` asks contributors
  to keep DCO sign-off intact through a rebase and prefers small, reviewed
  PRs. Squash-merge as the only allowed merge strategy keeps `main`'s
  history to one commit per PR and makes the "does the sign-off survive a
  squash" question GitHub answers automatically (it does, when every
  source commit already has one):
  ```sh
  gh repo edit morbstack/morbstack --enable-squash-merge \
    --enable-merge-commit=false --enable-rebase-merge=false \
    --delete-branch-on-merge
  ```

## 4. Branch protection on `main`

Configure before the first push, so nothing — including the repo
creator — accidentally force-pushes over the initial history once other
people may be watching the repo:

- Require a pull request before merging (no direct pushes to `main`,
  including from admins, once there's more than one maintainer — for a
  single-maintainer repo on day one, "include administrators" can be left
  off initially and turned on once a second maintainer joins, but decide
  that deliberately rather than by default).
- Require status checks to pass: the `build-and-test` and `lint` jobs
  from `.github/workflows/ci.yml` (the `guest-image` job is intentionally
  path-gated and slow — see the comment in that workflow file — so
  requiring it on every PR would block PRs that never touch guest-boot
  code on a check that never runs for them; do not mark it required).
- Require branches to be up to date before merging: on, so CI actually
  ran against what's about to land, not a stale base.
- Require conversation resolution before merging: on.
- Do not allow force pushes or deletions on `main`.

```sh
gh api repos/morbstack/morbstack/branches/main/protection \
  --method PUT \
  --input - <<'EOF'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["build-and-test", "lint"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1
  },
  "restrictions": null,
  "required_conversation_resolution": true,
  "allow_force_pushes": false,
  "allow_deletions": false
}
EOF
```

Note this API call targets a branch named `main` on the remote, which
only exists after step 6's first push — run this step *after* pushing,
not before, despite it being listed here as step 4 for narrative order.
(GitHub's UI-based branch protection setup has the same ordering
constraint: you cannot protect a branch that does not exist yet.)

## 5. Security Advisories

Enable **Settings > Code security and analysis > Private vulnerability
reporting**. This is the primary channel `SECURITY.md` documents — it
lets anyone privately open a draft security advisory against the repo,
which only maintainers can see until it's published, instead of filing a
public issue.

```sh
gh api repos/morbstack/morbstack/private-vulnerability-reporting -X PUT
```

Verify it took effect: `gh api repos/morbstack/morbstack/private-vulnerability-reporting`
should report `"enabled": true`.

Also worth turning on in the same settings panel, both free and low-effort
for a repo with no dependency manifests to speak of today (Swift/Rust are
both dependency-free per `NOTICE`) but cheap insurance for when that
changes:

- **Dependabot alerts** and **Dependabot security updates**.
- **Secret scanning** (and push protection, so a future accidental commit
  of a real credential is blocked before it lands rather than found
  after).

## 6. The initial push

```sh
git push -u origin main
```

That's the entire sequence — `origin` was already wired up by `gh repo
create --source=. --remote=origin` in step 2. After this, do steps 4
(branch protection) and 7 (GitHub Pages) against the now-populated repo.

## 7. GitHub Pages for the site

The marketing/docs site lives in `site/` (being built separately; not
this document's concern beyond how to publish it). Three ways to serve it
from this repo, in the order GitHub itself recommends today:

1. **A GitHub Actions workflow that deploys to Pages** (`actions/deploy-pages`).
   **Recommended.** Pages settings: `Source: GitHub Actions`. This is the
   only option of the three that can run a real build step (bundlers,
   static-site generators, whatever `site/` turns out to need) before
   publishing, rather than serving `site/`'s raw files verbatim — and it
   keeps the publish step auditable in the Actions log the same way CI
   already is, rather than being an implicit side effect of which branch
   HEAD happens to point to.
2. **Deploy from a branch, `/docs` folder on `main`.** Simple, but it
   requires whatever's under `site/` to physically live at a top-level
   `docs/` path, which collides with this repository's actual `docs/`
   directory (architecture, protocol, parity, roadmap — all real,
   already in heavy use). Not viable without renaming one of the two,
   which is not worth doing for this.
3. **Deploy from a branch, `gh-pages` branch.** Works, but needs a
   separate orphan branch kept in sync by hand or by a bot, which is
   exactly the job option 1's Actions workflow already does more
   transparently.

Recommendation: **option 1**, once `site/`'s own build tooling exists
(that worker's responsibility, not this document's). Until that workflow
exists, leave Pages disabled rather than half-configuring it against
nothing to deploy.

## 8. Secrets for the release workflow

`packaging/`, `scripts/release.sh`, and `.github/workflows/release.yml`
are owned by a different part of this project's build-out and are not
detailed here — see `docs/RELEASING.md` (once it exists) for exactly
which secrets that workflow needs (code signing identity, notarization
credentials, and whatever Sparkle update-feed signing needs, at minimum)
and how to add them via `gh secret set`. Do not add release-signing
secrets to this repository until that document says which ones and why;
an unused signing secret sitting in repo settings is pure risk with no
offsetting benefit.

## 9. Pre-flight checklist

Run every item below and read the actual output — this section is a
checklist to execute, not just to read.

- **No secrets in history.** Checked as part of preparing this document:

  ```sh
  git log --all -p | grep -iE 'api[_-]?key|password *=|BEGIN (RSA|OPENSSH|DSA|EC) PRIVATE KEY|secret_key|AKIA[0-9A-Z]{16}'
  ```

  This does find hits — all of them are fake, fixture data in
  `mac/Sources/MorbstackAppCore/Shots/ShotFixtures.swift` and
  `ShotLogs.swift` (the offscreen screenshot/demo harness's canned
  Docker world — `STRIPE_API_KEY=sk_live_51Nq8fLK2mQpZ3xVb7YdT`,
  `POSTGRES_PASSWORD=hunter2`, and similar), used to make demo
  screenshots of a container's environment-variables panel look like a
  real one. None of them are live credentials; `hunter2` in particular is
  the standard joke placeholder. Worth a second human look before
  publishing regardless, precisely because "the automated check flagged
  it and a human decided it was fine" is a better record to have than no
  check at all — re-run this grep after any future commit and don't
  wave a future hit through on the assumption it's more fixture data
  without actually looking.

- **`.gitignore` covers build artifacts.** Verified: `.build/`,
  `.swiftpm/`, `target/`, and `dist/*` (with narrow allow-list
  exceptions for `PROVENANCE.txt` files and `dist/CROSS_COMPILE.md` — see
  `NOTICE` for why the vendored guest payloads themselves are excluded)
  are all ignored. Confirm nothing large snuck in anyway:

  ```sh
  git ls-files dist/
  ```

  Should print only `PROVENANCE.txt` files and `CROSS_COMPILE.md` — no
  binaries.

- **Repo size.**

  ```sh
  du -sh .git
  ```

  22M as of this writing — small, no accidentally-committed large
  binaries inflating history. Re-check after any bulk import (e.g. if
  screenshots or brand assets were ever committed and later removed —
  removal alone doesn't shrink `.git`; that needs history rewriting,
  which is its own separate, deliberate decision this document does not
  make for you).

- **License and attribution files are present and consistent.**
  `LICENSE` (unmodified Apache-2.0 text), `NOTICE` (third-party
  component attribution — see that file for exactly what is and is not
  redistributed by this repository itself), `CODE_OF_CONDUCT.md`, and
  `SECURITY.md` all exist at the repo root, which is where GitHub looks
  to surface them in its own UI (the "Community Standards" checklist
  under `Insights > Community`). Check that checklist once the repo is
  public — it will flag anything GitHub can't find.

- **Remaining `TODO(human)` markers.** Grep for them and resolve what you
  can before announcing the repo publicly (some — like the DCO/CoC
  contact email — block nothing technical but do matter before real
  reports start arriving):

  ```sh
  grep -rn "TODO(human)" --include="*.md" --include="*.yml" .
  ```

- **One build entry point, not two, in anything you publish alongside
  this repo.** The build system migrated to `mise.toml` (`mise run
  <task>`) as the single source of truth partway through preparing this
  repo for publishing; the root `Makefile` is now a thin compatibility
  shim that forwards every `make <target>` to the matching `mise run
  <target>` and is documented as such in its own header comment. This is
  fine to publish as-is — the shim keeps old muscle-memory working — but
  if a blog post, tweet, or launch-day writeup gives build instructions,
  give `mise run build`/`mise run test`, not `make build`/`make test`, so
  a first-time visitor lands on the primary path rather than the
  transitional one.
