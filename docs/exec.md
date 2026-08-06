# The container terminal — interactive exec, honestly

Morbstack has two ways to run something inside a container, and they are different
features on purpose:

* **Run Command** (`ContainerExecSheet`) — a bounded, noninteractive command with a
  finite result document. Stdin closed, no TTY, stdout and stderr kept separate. It
  says exactly that in its own copy, and it is the right shape for "what does
  `cat /etc/os-release` say in there".
* **Open Terminal** — a real interactive shell in its own window: a TTY, a live
  screen, colours, `vim`, `htop`, resize, scrollback, copy and paste.

This document is about the second one: how it talks to the Engine, how it renders,
what it handles, and what it does not.

## Why a sibling, not a bigger sheet

`ContainerExecSheet` was left alone. Its header says why it exists: "Interactive
stdin, a TTY, shell parsing … are separate capabilities that need their own real
transport contracts." Growing the sheet into a terminal would have replaced a
correct, deliberately bounded feature with a different feature wearing its name.
The terminal is new code end to end: transport, screen model, view, window.

The window is a programmatic `NSWindowController`, not a SwiftUI scene, and it is
marked non-restorable. A terminal session dies with its socket; relaunching the app
must never resurrect a window attached to a shell that no longer exists.

## Where it is reached from

Three places, all reading the same enablement function
(`Terminal/ContainerTerminalAvailability.swift`) so they cannot drift apart:

* the Containers row's **contextual menu**, directly above Run Command — the two ways
  to run something inside a container sit adjacent and differently named, so the
  choice between them is made with both visible;
* the **toolbar's secondary-action area** for the selected record
  (`containers.openTerminal`), beside `containers.runCommand`;
* the menu bar's **Container** menu, with ⌃⌘T. A command that exists only in the
  toolbar becomes unreachable the moment the system overflows it away at a narrow
  width.

Not in `ContainerDetailView`. That view's own header states the rule it follows —
"an information inspector, not a second hand-built application chrome" — and a
command that opens a window is chrome.

**A stopped container has no process namespace to enter.** `POST
/containers/{id}/exec` refuses it, and so does the affordance: disabled, with
`.help()` naming the single step that would make it work ("Start pg-main to open a
terminal in it"), rather than an error after the click. `dead` is the state with no
remedy, so its copy offers none. A `--tour-fixtures` window has no engine at all and
is disabled for that reason instead.

## The transport: a hijacked exec

`Terminal/DockerExecPTYSession.swift` performs the same exchange the Docker CLI does:

1. `POST /containers/{id}/exec` — create the exec instance
   (`AttachStdin`, `AttachStdout`, `AttachStderr`, `Tty`, `Cmd`).
2. `POST /exec/{id}/start` on a dedicated connection, carrying
   `Connection: Upgrade` and `Upgrade: tcp`, body `{"Detach":false,"Tty":…}`.
   After the Engine's reply the connection stops being HTTP: bytes written are the
   process's stdin, bytes read are its screen output.
3. `POST /exec/{id}/resize?h={rows}&w={cols}` — a separate, ordinary HTTP request,
   sent after start and again whenever the view's grid changes. Resizes are
   coalesced: a live window drag sends the latest size, not every intermediate one.
4. On stream EOF, `GET /exec/{id}/json` reports the exit code. If there is none and
   the container itself is no longer running, the window says the container stopped
   rather than inventing an exit status.

Hijack confirmation is two-sided, mirroring the daemon proxy's own contract
(`docs/audit/PROXY-FRAMING.md` §2.4): a `101 Switching Protocols`, or a `2xx` whose
content type is a Docker raw/multiplexed stream, and only then does the session
treat the socket as raw. Stream bytes that arrive in the same read as the response
head are not dropped. The proxy nominates `POST /exec/{id}/start` as a hijack
candidate on the request side and confirms on the response side, so the app's bytes
splice exactly like the CLI's do — that path was already tested before this feature
existed, and this feature leans on it rather than re-plumbing it.

Non-TTY sessions (`tty: false`, the piped `docker exec -i` shape) use the same
class: stdout and stderr arrive multiplexed in Docker's 8-byte stdcopy framing and
are demultiplexed with the same decoder the log viewer trusts. `closeStdin()` is a
half-close — the process sees EOF on stdin and its remaining output still drains.

## The screen model

`Terminal/TerminalEmulator.swift` is a real VT/xterm state machine, not a log view
with colours. Bytes in, cells out; no I/O, no views, directly unit-tested. It
implements the set an interactive Linux userland actually exercises:

* cursor addressing, tabs, insert/delete of characters and lines;
* erase in line/display, including `ED 3` clearing scrollback;
* scroll regions (`DECSTBM`), forward and reverse index honouring the margins;
* the alternate screen (`47`/`1047`/`1049`) — `vim`, `htop` and `less` run there,
  and primary scrollback is preserved across the round trip;
* SGR: 16 colours, bright, 256-colour, truecolor, bold/dim/italic/underline/
  inverse/strikethrough, including the colon-separated parameter forms;
* DEC special graphics (line-drawing) charset via `SO`/`SI` and `ESC ( 0`;
* deferred wraparound — the last-column pending-wrap rule shells depend on;
* origin mode, autowrap on/off, cursor save/restore, `DECALN`, `RIS`;
* the replies programs block on: `DA1`, `DA2`, `DSR`, cursor position reports;
* incremental UTF-8 (sequences split across reads), combining marks, and
  double-width characters occupying two cells.

Scrollback is capped at 10,000 lines and exists only on the primary screen —
full-screen programs do not pollute it. Resize does not reflow lines; xterm behaves
the same way, and the gap is recorded below rather than papered over.

## Keys, selection, paste

Arrow keys respect `DECCKM` (`vim` gets `SS3 A`, a shell gets `CSI A`). `⌃C`, `⌃D`,
`⌃Z` and friends fold to their C0 bytes. `⌘C` copies the selection — it never sends
an interrupt; `⌃C` does that. Escape goes to the process, never to the window.
Paste is bracketed when the program asked for bracketed paste, and newlines are
normalised to `\r`, which is what a terminal sends. Selection works across
scrollback, double-click selects a word, triple-click a line.

## Shell choice, and the honest failure

`Terminal/TerminalShellResolution.swift` probes `/bin/bash` then `/bin/sh` with a
bounded noninteractive exec per candidate (`<shell> -c "exit 0"`) and starts the
first that runs. A container with neither — a distroless image — gets a plain
statement of that fact in the window, naming the candidates it tried and pointing at
Run Command for a binary the image does ship. No spinner, no stack trace, and no
promise of a toolbox that does not exist.

That typed outcome remains the seam a debug toolbox would grow through
(`docs/debug.md`): a toolbox that brings its own shell becomes a new resolution
outcome feeding the same terminal, not a rewrite of it.

## Untrusted input

Everything arriving from the guest is bytes an attacker chose, if the container is
theirs. `TerminalEmulator` is written to that assumption and
`TerminalEmulatorHostileInputTests` is the executable form of this section.

What is defended:

* **`OSC 52` is not implemented and must not be.** It is the clipboard read/write
  sequence: the write form would let a container replace what the person is about to
  paste into a shell on their own machine; the read form would exfiltrate the
  pasteboard through the container's own stdout. OSC dispatch is an allow-list
  (`0`/`2` only) precisely so 52 falls into the discard branch.
* **Window titles are sanitised.** `OSC 0`/`OSC 2` is attacker-controlled text that
  reaches `NSWindow.title`. C0/C1/DEL are stripped (a `\n` corrupts anything that
  later logs the title), bidi and invisible formatting controls are stripped (the
  Trojan Source technique — text that reads as one thing and is another), and the
  result is capped at 128 characters. The window's own `<name> — <shell>` prefix
  always precedes it, so a container cannot make its window impersonate another.
* **Replies never echo the guest's bytes.** DA1, DA2, DSR and CPR are fixed literals
  plus coordinates the emulator computed itself.
* **Every accumulator is bounded**, and a sequence past its bound is *abandoned*,
  not truncated and executed: 128 bytes of CSI parameters, 4 KB of OSC/DCS payload,
  `CSI b` (repeat) capped at one screenful.
* **Every write clamps to the live grid** before touching storage; a fuzz soak and a
  resize-under-load soak assert the grid stays rectangular and the cursor in bounds.
* **DCS/APC/PM/SOS payloads are swallowed**, so a program's private data never
  sprays across the screen as text.
* **Mouse reporting is a deliberate non-feature.** Modes 1000–1006 are accepted and
  discarded, so no pointer position is ever reported into the guest.
* **Bracketed paste strips an embedded terminator** from the clipboard payload.
  Without that, text carrying `ESC [201~` closes the fence early and the remainder
  reaches the shell as typed input — a clipboard that can run a command.

What is *not* defended, stated plainly:

* A container **can** set the window title, within the sanitiser's limits. That is
  the feature; the mitigation is the prefix and the cap, not prevention.
* A container **can** emit whatever glyphs it likes, including ones that visually
  imitate this app's own UI, inside the terminal's content area. Terminal emulators
  do not solve this and neither does this one.
* A container **can** ring the bell (`NSSound.beep()`) as often as it writes `0x07`.
  There is no rate limit.
* Selection and copy put the *rendered* text on the pasteboard. A container can
  therefore influence what a person copies if they copy from its output — the same
  exposure every terminal has, and the reason `⌘V` into a shell is bracketed.

## Teardown

Closing the window shuts the session's socket; a TTY exec's shell receives SIGHUP
through the closed pseudo-terminal. Docker does not promise a plain (non-TTY) exec
process dies with its attachment, and this document will not promise it either.
A container that stops mid-session ends the stream; the window keeps the scrollback
readable and says what happened in one line at the bottom.

## Verified against a live engine

**Not yet.** As of 2026-08-05 the screen model, the key encoder, the transport, the
shell probe, and the affordance's enablement are covered by 141 unit tests, and the
fixture XCUITest asserts the disabled state. Nobody has yet held a real shell open
against a running container: that needs the machine lane (`mise run app`, a signed
bundle, a booted engine) and is the outstanding acceptance step for DIF-2. Until it
happens, no claim in this document about *interactive* behaviour — typing latency,
`vim` and `htop` under a real PTY, resize during a live window drag, SIGHUP on close
— has been observed rather than reasoned about.

## Known limits

Stated, not hidden:

* **No reflow on resize.** Narrowing the window truncates line storage at the new
  width (like xterm, unlike Terminal.app and iTerm2).
* **No application keypad mode.** `ESC =` / `ESC >` are consumed and ignored, so the
  numeric keypad always sends digits. Programs that assume DECKPAM get plain numbers.
* **G2/G3 charsets are designable but unreachable** — there is no SS2/SS3 locking
  shift, so only G0 and G1 (via `SO`/`SI`) select a charset.
* **`ED 3` clears scrollback but `47`/`1047` alternate-screen entry always starts
  blank**, where xterm's mode 47 retains the alternate buffer's previous content.
* **No mouse reporting.** Programs that ask for xterm mouse modes (1000–1006) get
  no mouse events; `htop` is keyboard-only here, `vim` mouse selection falls back
  to the terminal's own selection.
* **No IME / dead-key composition.** Input goes through `keyDown`, not a full
  `NSTextInputClient`; typing accented characters via composition, or CJK input
  methods, will not compose. ASCII, pasted text of any script, and direct Unicode
  keystrokes are fine.
* **East Asian width is approximated** from Unicode block ranges, not the full
  UAX #11 tables.
* **One session per window, no reconnect.** A dropped connection is reported, not
  silently redialed — an exec instance cannot be re-attached after its stream ends.
* **Scrollback selection can drift** by a line once the 10,000-line cap starts
  trimming while a selection is held.
* **`morb` has no `exec` subcommand.** The CLI story for interactive exec remains
  `docker exec` through the socket; this feature is the app's terminal.
