# Per-user background service decision

Morbstack's durable helper is a per-user `LaunchAgent`, registered only through
`SMAppService.agent(plistName:)` when the person explicitly asks to enable it. It is
not a privileged `LaunchDaemon`: Morbstack owns only the signed-in user's VM,
`~/.morbstack` state, Unix sockets, and loopback forwards, so root execution and
pre-login operation would add authority without a product need.

Apple's current guidance is to keep helper plists inside the signed app bundle at
`Contents/Library/LaunchAgents`, use `BundleProgram` rather than writing a plist into
`~/Library/LaunchAgents`, and query `SMAppService.status` for authorization state.
Registration is user-visible in Login Items and must tolerate the service being
disabled there. Sources: [Service Management](https://developer.apple.com/documentation/servicemanagement), [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice), [updating helper executables](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos), and [managing ongoing background processes](https://developer.apple.com/documentation/appkit/managing-ongoing-background-processes-in-your-mac).

The command foundation is intentionally explicit and idempotent: `status` never
registers, `enable` treats already-registered as success, `disable` treats an absent
service as success, and opening Login Items is a separate direct request. No build,
app launch, daemon start, or installation path registers a background service.

After the explicit `enable` request, Morbstack waits briefly for the authorized
LaunchAgent to bind its control socket and reports the observed result. This is a
bounded connection-only probe: it does not send a daemon command, boot the VM, or
start containers. A successful Login Items registration therefore remains distinct
from proof that a new shell can immediately reach the windowless Docker host; a
missing or unresponsive socket is reported for repair rather than papered over by
starting a second daemon.

If a newer macOS reports a Service Management state this build does not recognize,
Morbstack does not unregister or replace the existing service. The command reports the
state and directs the person to Login Items. Likewise, Morbstack records an update
receipt only after macOS reports the service as enabled or awaiting approval; a
successful API call with an unresolved status is not treated as proof that this app
bundle owns a healthy agent.
