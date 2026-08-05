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
bounded noninteractive exec per candidate and starts the first that runs. A
container with neither — a distroless image — gets a plain statement of that fact
in the window, not a spinner and not a stack trace.

That typed outcome is deliberately the seam for the debug toolbox (`morb debug`,
`docs/debug.md`): a toolbox that brings its own shell becomes a new resolution
outcome feeding the same terminal, not a rewrite of it. The toolbox does not exist
yet, and the terminal says so.

## Teardown

Closing the window shuts the session's socket; a TTY exec's shell receives SIGHUP
through the closed pseudo-terminal. Docker does not promise a plain (non-TTY) exec
process dies with its attachment, and this document will not promise it either.
A container that stops mid-session ends the stream; the window keeps the scrollback
readable and says what happened in one line at the bottom.

## Verified against a live engine

*This section is filled in from the live matrix run; see the dated results below.*

## Known limits

Stated, not hidden:

* **No reflow on resize.** Narrowing the window truncates line storage at the new
  width (like xterm, unlike Terminal.app and iTerm2).
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
