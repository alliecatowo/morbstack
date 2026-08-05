# The Morbstack MCP server

`morb mcp` exposes Morbstack to an AI agent over the Model Context Protocol. Six places in the
source cite this document — two of them in strings the *agent itself* reads at runtime — so it is a
contract, not an overview. If you change the permission model, the redaction behaviour or the audit
record, change this file in the same commit.

## What makes this surface different

Every other entry point into Morbstack is driven by a person who typed something. This one is driven
by a model deciding what to call, and that model may be acting on text it read from a web page, a
README, or a container's own log output. **Assume the caller can be influenced by input it did not
originate.** That single assumption is what the permission model, the redaction and the audit log
are all built around.

## Permission model

**Read-only by default, and that is enforced structurally rather than by convention.**

- A tool is ungated if and only if its `group` is `nil`. All thirteen mutating tools carry a group.
- The check sits on the single path every call crosses (`callTool`), not on each tool. This matters:
  a per-tool check is one a new tool can forget, and the worst bug in this project's history was a
  guard that was correct, unit-tested, and never actually ran because the path around it was the
  common one.
- Grants come from `mcp.toml` or `--allow`. **`deny` always wins**, and `--allow` rejects an
  argument it does not recognise rather than silently ignoring it.
- Nothing in the environment widens the grant set.

A test pins the ungated tool set **by name**, so a tool registered without a group fails the suite
instead of shipping ungated. If you add a tool, that test is the thing that will tell you.

### Fine-grained guards

Some grants are deliberately narrower than their group. `container_remove:force` exists so that
`containers:write` does **not** imply force-killing a running container. Treat a guard like this as
load-bearing: MCP-1 below was serious precisely because it defeated one.

## Threat model

Cited by `Utilities.swift` and `Audit.swift`. The fuller argument:

**"Read-only" and "safe to hand to an untrusted prompt" are different properties.** `Config.Env` is
where `DATABASE_URL`, `AWS_SECRET_ACCESS_KEY` and every other container credential typically lives.
A tool that can only *look* is still a complete secrets-exfiltration path if what it looks at
includes those values. That is why `container_inspect` redacts `Config.Env` down to shape — which
variables are set, how long each value is — and why `inspect:env` is the grant that opts back into
the unredacted document.

**What the audit log can and cannot prove.** It records that a client with this grant set asked for
this tool with these arguments and reached this outcome. It does **not** prove the agent's intent,
and it cannot prove the request came from the human at the keyboard rather than from a
prompt-injected instruction the agent followed in good faith. The trust boundary for *that* is the
MCP client, not this server. Do not design as though the log closes it.

## Redaction is best-effort. It is not a guarantee.

This is the sentence the runtime strings point at, so it is stated plainly:

`best_effort_pattern_match` means exactly that. `LogRedactor` exists to stop the **routine** case —
an app logging its own connection string, an SDK logging a bearer token at debug level — from being
handed to an agent by a tool that needs no grant. It does not make `container_logs` safe against a
container that logs secrets in a form the patterns do not match, and it does not try to.

**Do not read the presence of redaction as "logs are sanitised."** If a container handles secrets
you care about, do not grant log access to an agent.

## The audit log

Every `tools/call` outcome is recorded, including refusals — a call rejected for want of a grant,
and (since the MCP-2 fix) a call that arrived before `initialize`. That last one mattered because
without it "no record" meant either "never asked" or "asked out of order", which is exactly the
ambiguity the log exists to remove. Records are JSON-escaped, so a caller cannot forge or inject
entries.

### Limitations

Cited by `Audit.swift`. Two, stated honestly:

1. **A failed write is swallowed, and the record is lost.** A tool call that already succeeded or
   failed on its own terms must not be re-reported to the client as broken because *logging* it hit
   a snag. That is the right trade, and it is still a real gap: the log is evidence, not a ledger.
2. **The log stores up to 500 characters of tool output.** With `inspect:env` granted, that means
   `Config.Env` values can land in it. Filed as SEC-4 — the fix is a ruling about what the log is
   *for*, not a patch.

## MCP-1 — what a `/` in an identifier used to do

Fixed 2026-08-05, recorded because the shape recurs.

`EngineClient.path` percent-encoded query *values* but not the path, and the path went straight into
the HTTP request line. A CRLF in a container id — from `container_inspect` or `container_logs`,
**neither of which needs a grant** — terminated the request line early, so Morbstack's own
`Connection: close` header landed on whatever the caller wrote after the blank line and the engine
read two pipelined requests. The second could be `DELETE /containers/x` or `POST /volumes/prune`:
the entire mutating surface, ungated, and audited as a read-only inspect.

A `?` was the narrower version. Go returns the first value for a repeated query parameter, so
`container_remove` with `id: "web?force=1&"` sent `force=1` while the tool believed it sent
`force=0`, defeating `container_remove:force`.

The fix **encodes rather than rejects**, at the choke point every Engine request crosses: the engine
percent-decodes before route matching, so an odd but honest name still reaches the right handler and
the fix stays total. `Identifiers.swift` is a second layer, because `/` stays literal in a path and
`web/json` would otherwise still reshape which route matches.

**The lesson worth keeping:** an identifier that reaches a wire format is attacker-controlled input
even when it arrives through a read-only tool.

## Reading the audit log

The log is newline-delimited JSON at `$MORBSTACK_HOME/logs/mcp-audit.jsonl`. Read it with ordinary
tools:

```bash
tail -f ~/.morbstack/logs/mcp-audit.jsonl | jq .
```

`Audit.readAll` exists in the source and refers to a `morb mcp audit` subcommand. **That subcommand
is not implemented.** Use the file directly until it is.
