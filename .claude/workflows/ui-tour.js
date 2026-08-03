export const meta = {
  name: 'ui-tour',
  description: 'Click through every view of the running Morbstack app with computer use, then dogfood it against a live engine to prove the UI actually works',
  whenToUse: 'After any UI change, or whenever you want an honest read of the real app. Uses real screenshots of the real window — NOT the offscreen MorbShots renders, which cannot composite toolbars, inspectors or glass and have misled this project before. Phase 2 verifies the app performs real work, not just that it renders.',
  phases: [
    { title: 'Tour', detail: 'drive every view, capture real screenshots, critique' },
    { title: 'Dogfood', detail: 'drive real container work FROM the app against a live engine' },
  ],
}

const ROOT = '/Users/allie/Develop/morbstack'

phase('Tour')

const report = await agent([
  'You are running a VISUAL CLICK-THROUGH of the real Morbstack desktop app (SwiftUI, macOS 26 Tahoe) and reporting honestly on how it looks and behaves.',
  '',
  'WHY THIS EXISTS: the offscreen screenshot harness (MorbShots -> dist/shots/*.png) renders into a borderless window and CANNOT composite toolbars, navigationTitle, inspectors, or Liquid Glass. It has repeatedly shown chrome that does not exist in the real app. Only real screenshots of the real window count. Never cite dist/shots as evidence.',
  '',
  '== SETUP ==',
  '1. Call request_access for the app "Morbstack" (bundle dev.morbstack.app) before any computer-use action. If it is denied, stop and report that — do not fall back to screencapture or CGWindowList, both are TCC-blocked here.',
  '2. Ensure a build exists at ' + ROOT + '/dist/Morbstack.app. If it is missing, run `make app` — but FIRST check whether another agent is mid-build (look for running swift processes); if so, wait rather than racing it.',
  '3. Launch with ' + ROOT + '/scripts/ui-tour.sh <view> <appearance> <size>. Add --fixtures for a populated UI when no engine is running. Stop it with ./scripts/ui-tour.sh --stop when finished.',
  '',
  '== THE TOUR — click, do not just relaunch ==',
  'Launch once, then NAVIGATE BY CLICKING so you also verify navigation works. Screenshot each state and zoom into anything suspicious.',
  'Sidebar: Containers, Stacks, Kubernetes, Images, Volumes, Networks, Builds, Disk.',
  'Container detail: select a container, then click through Overview, Logs, Stats, Inspect.',
  'Chrome: the command palette (Cmd-K), Settings (Cmd-,) and every settings tab, the menu-bar popover (click the status item), and each menu in the menu bar.',
  'Window behaviour: resize the window small and large and note anything that breaks; toggle the sidebar; scroll a long list and watch how content passes under the toolbar.',
  'Run the whole tour in BOTH dark and light appearance.',
  '',
  '== WHAT TO JUDGE ==',
  'You are looking for anything that betrays a non-native, hand-drawn app. Specifically:',
  '- Is there a REAL window toolbar with title, subtitle, search and actions, or is the header painted inside the content view?',
  '- Do the traffic lights sit over a full-height sidebar (Finder/Xcode-style), or is there a dead titlebar strip above it?',
  '- Is selection drawn by the system (plain rounded capsule) or hand-drawn (accent rails, custom pills)?',
  '- Are materials correct — sidebar vibrancy present, and NOT doubled up where the system already provides material?',
  '- Are tables real Tables with sortable columns, or custom rows pretending?',
  '- Empty states: ContentUnavailableView, or a hand-built tinted circle and pill?',
  '- Typography, alignment, monospaced numerics, spacing rhythm, contrast in both appearances.',
  '- Anything that is simply broken: clipped text, overlapping views, blank panes, dead space, a control that does nothing.',
  '',
  '== REPORT ==',
  'Write ' + ROOT + '/docs/design/TOUR-REPORT.md: one section per view with what you saw, a verdict (native / suspect / clearly hand-drawn), and specific defects. Rank the top ten fixes by how much each would improve the impression of nativeness. Be blunt — this document exists to be acted on, and a flattering report is worthless.',
  'Also save the screenshots you took into ' + ROOT + '/dist/tour/ with descriptive names so they can be diffed against the next tour.',
  '',
  'Finally: stop the app (./scripts/ui-tour.sh --stop) and leave nothing running.',
  '',
  'Final message: the top five defects, anything that is broken rather than merely ugly, and an overall verdict on whether this reads as a native Mac app.',
].join('\n'), { label: 'ui-tour', phase: 'Tour', model: 'sonnet', effort: 'high' })

phase('Dogfood')

const dogfood = await agent([
  'You are DOGFOODING the Morbstack desktop app: proving the UI actually performs real work against a live engine, not merely that it renders. A beautiful app whose buttons do nothing is worse than an ugly one that works.',
  '',
  'Visual tour findings from the previous agent (context, not your task): ' + String(report).slice(0, 2000),
  '',
  '== RULES THAT HAVE BURNED THIS PROJECT ==',
  '- Call request_access for "Morbstack" before any computer-use action.',
  '- `swift build` STRIPS the virtualization entitlement from morbstackd. If another agent is building, your daemon dies mid-test. Build and `make sign` ONCE, then copy the signed binaries somewhere private and run those.',
  '- The user has Docker Desktop credsStore in ~/.docker/config.json which HANGS the docker CLI. Always use DOCKER_CONFIG=<scratch dir>. NEVER touch ~/.docker.',
  '- Foreground only: no nohup, no backgrounded composites with sleeps. Kill only by PID.',
  '- Use a SHORT MORBSTACK_HOME path (e.g. /tmp/morbdog) — long paths blow the 104-byte unix socket limit.',
  '',
  '== THE POINT: every assertion is UI action -> CLI verification ==',
  'For each step, DO IT IN THE APP by clicking, then INDEPENDENTLY VERIFY with the docker CLI or `morb` that the underlying state really changed. A UI that lies about state is the specific failure mode you are hunting.',
  '1. ENGINE LIFECYCLE: with the engine stopped, click "Start Engine" in the app. Does it start? How long until the UI reports running? Verify with `morb status`. Then stop it from the app and verify it really stopped.',
  '2. LIVE UPDATES: with the app open on Containers, start a container from the CLI (`docker run -d --name dogfood-nginx -p 18099:80 nginx:alpine`). Does the app show it WITHOUT a manual refresh, and how fast? This exercises the event stream. Then stop it from the CLI and watch the row update.',
  '3. CONTAINER ACTIONS FROM THE UI: using only the app, stop / start / restart a container, and verify each with `docker ps`. Then remove one from the app and confirm it is gone.',
  '4. LOGS: open the Logs tab on a container that is actively producing output. Do lines stream live? Does follow/tail work? Does the filter field actually filter? Are ANSI colours rendered rather than printed as escape codes? Try a container emitting 10k lines and see whether scrolling stays smooth.',
  '5. STATS: does the Stats tab show plausible, moving CPU/memory values that match `docker stats`?',
  '6. EXEC / INSPECT: does Inspect show real inspect JSON, and does search within it work?',
  '7. PORTS: click a published-port link in the app and confirm it opens the right URL and that the service actually answers.',
  '8. IMAGES: pull an image FROM the app and watch progress; verify with `docker images`. Remove an image from the app; verify it is gone. Try removing an in-use image and confirm the error is explained rather than swallowed.',
  '9. DISK: compare the app Disk figures against `docker system df`. Run a prune from the app, confirm the preview matched what was actually deleted, and that reclaimed bytes are honest.',
  '10. COMPOSE / STACKS: bring up a two-service compose project from the CLI and confirm the Stacks screen groups it correctly and that its per-stack actions work.',
  '11. FAILURE HANDLING: stop the engine while the app is open on a busy screen. Does the app degrade gracefully with a clear message, or hang, spin, or show stale data as if live? Restart the engine and confirm it recovers on its own.',
  '',
  'Clean up every container, image and volume you created, stop the app and the engine, and leave the machine as you found it.',
  '',
  'Write ' + ROOT + '/docs/design/DOGFOOD-REPORT.md: per step, what you did in the UI, what the CLI showed, and PASS / PARTIAL / FAIL with evidence. Call out anything where the UI showed one thing and reality was another — those are the most serious defects we can have.',
  '',
  'Final message: what genuinely works end to end, what is broken, and the single worst discrepancy between what the UI claims and what is true.',
].join('\n'), { label: 'dogfood', phase: 'Dogfood', model: 'sonnet', effort: 'high' })

return { report, dogfood }
