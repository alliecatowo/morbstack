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
