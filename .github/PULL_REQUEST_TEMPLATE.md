## What and why

<!-- What does this change, and why? Link the issue it addresses if there is one. -->

## Tests run

- [ ] `mise run build && mise run test` passes locally (Swift + Rust suites)
- [ ] If this touches `guest/morbinit`'s `#[cfg(target_os = "linux")]` code, or anything needing a real guest boot, I ran `mise run guest-image` and verified against a real VM
- [ ] If this touches a behavior covered in `docs/parity.md`, I re-ran the relevant check by hand and noted the before/after below

## Docs

- [ ] I updated the relevant `docs/*.md` file(s) in this same PR, or this change doesn't need a docs update

## DCO

- [ ] Every commit in this PR has a `Signed-off-by` trailer (`git commit -s`) — see `CONTRIBUTING.md`

## Notes for reviewers

<!-- Anything a reviewer should know: known limitations, follow-up work, things you're unsure about. -->
