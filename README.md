<p align="center">
  <img src="extension/icon.png" width="128" height="128" alt="apple-mail-mcp icon">
</p>

# apple-mail-mcp

A local MCP server, written in Swift, exposing the macOS **Mail** app to Claude. It ships
as a Claude extension.

Not affiliated with or endorsed by Apple Inc.

## How this one differs

Contacts and Calendar have native frameworks. **Mail does not.** MailKit exists, but it
only builds extensions that run *inside* Mail — an external process cannot use it to read
a mailbox. The only route is Apple events, so this server drives Mail.app through
`ScriptingBridge.framework`.

Three consequences you will feel:

- **Mail must be running.** This server will not launch it. Starting an app on your behalf
  is a side effect you did not ask for, and Mail can churn for a long time on first launch.
- **It is slow.** Every read is Mail walking a mailbox and shipping results across the
  Apple event boundary. Always bound a search by mailbox and date.
- **The permission is Automation**, not a Mail-specific toggle, and it is granted per
  target app.

## Requirements

- macOS 15 or later
- Swift 6.0 or later (Xcode 26 ships it)
- A code signing identity. Ad-hoc works, but every rebuild then asks for permission
  again — see [Signing](#signing-and-why-it-is-not-optional).

## Tools

| Tool | Kind | What it does |
|---|---|---|
| `mail_status` | read | Reports whether Mail is running, whether automation is permitted, and the fixed defaults in force. Sends no Apple event. |
| `mail_accounts` | read | Accounts, addresses, mailboxes and unread counts. |
| `mail_search` | read | Messages by sender or subject, bounded by mailbox and date. Newest first. |
| `mail_get` | read | Headers and body of one message. Does not mark it read. |
| `send_mail` | **irreversible** | Sends an email. Requires `confirm: true`. |

**No tool can delete, move or alter a received message.** Mail's scripting dictionary
offers `delete`, `move`, `bounce` and `redirect`; none of them is exposed, and a test
enforces that. A mailbox is a record.

### send_mail

The only outward-facing tool in the whole project. There is no recall, no undo, no draft
to fall back on. It requires `confirm: true`, validates every address before it will
consider sending, and returns a receipt listing every recipient — **including bcc** —
because that receipt is the only record you get of something that cannot be taken back.

`from` picks which of your own addresses the message leaves from. One account often owns
several, and Mail otherwise chooses its default; worse, it accepts an address it does not
own and silently substitutes that default, so a typo would send under the wrong identity
and still report success. `from` is therefore checked against what `mail_accounts`
returns, and an unknown address is refused with the real list. Omit it to keep Mail's
default.

Switch it off if you only want Claude to read.

## Install

### 1. Build the bundle

```bash
MCPB_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/pack.sh
```

That builds a universal (arm64 + x86_64) release binary, signs it, checks the embedded
`Info.plist` survived both linking and signing, prints the designated requirement, and
writes `dist/apple-mail-mcp.mcpb`. It fails loudly rather than shipping a bundle that
would silently refuse to work.

```bash
security find-identity -v -p codesigning
```

### 2. Install it

Open `dist/apple-mail-mcp.mcpb` with Claude. Then **quit Claude Desktop completely and
reopen it** — reinstalling does not replace a server process that is already running, and
the old one keeps answering.

### 3. Grant the permission

Open Mail first; the server will not launch it for you.

Call `mail_status`. It reports the permission state **without sending an Apple event** —
it asks the system directly via `AEDeterminePermissionToAutomateTarget` with
`askUserIfNeeded: false` — so it is always safe to call first when something is failing.

Then call `mail_accounts`. macOS raises *"apple-mail-mcp wants to control Mail"*. Approve
it, and the grant appears under System Settings → Privacy & Security → Automation
(Spanish UI: Ajustes del Sistema → Privacidad y seguridad → Automatización).

The binary is **its own privacy subject**: Claude Desktop launches MCP servers through
`Contents/Helpers/disclaimer`, which calls `responsibility_spawnattrs_setdisclaim`.
Sending Apple events needs `NSAppleEventsUsageDescription`, embedded at link time.

If no dialog ever appears:

```bash
otool -P extension/server/apple-mail-mcp | grep NSAppleEventsUsageDescription
```

### Signing, and why it is not optional

`swift build` leaves a signature the linker generated, flagged `linker-signed`. macOS
treats that as signed by nobody: it produces **no designated requirement**, so there is
nothing to anchor a permission to except the binary's cdhash — and every rebuild changes
that. Worse, a linker-signed binary never gets a consent dialog at all; the request
returns with the status still "not determined".

Signing with a real certificate produces a requirement anchored to the bundle identifier
and the certificate instead:

```
designated => identifier "codes.eneko.apple-mail-mcp" and anchor apple generic
              and certificate leaf[subject.CN] = "Apple Development: …"
```

That survives rebuilds — verified by installing two builds with different cdhashes and
the same identity, with no second consent dialog. `pack.sh` prints the requirement on
every build, so a silent regression to ad-hoc is visible immediately.

Automation grants behave slightly differently from the others: they are recorded per
source-and-target pair and observably survived a change of signing identity, where
Contacts and Calendar did not. Do not rely on that.

### Preparing something to distribute

```bash
MCPB_HARDENED=1 MCPB_SIGN_IDENTITY="Developer ID Application: …" ./scripts/pack.sh
```

`Resources/entitlements.plist` is applied automatically. It has to be: the hardened
runtime blocks Apple events outright unless `com.apple.security.automation.apple-events`
is granted, before the permission system is even consulted, and this server would stop
working entirely without it.

## Plug and play

There is nothing to configure. What used to be four settings — default mailbox, messages
scanned per search, message body characters, default search results — are now fixed
constants in `Configuration`, at the values this server already shipped with. The only
thing left to adjust in Claude Desktop → Settings → Extensions is the per-tool switch
below. `mail_status` reports the fixed defaults in force, which is the quickest way to
confirm which build is answering.

## Tool switches

Every tool can be turned on and off individually, because the bundle declares them all in
its manifest. That is where policy lives — not in this code. Turning off `send_mail`
leaves a strictly read-only server.

**Reinstalling may reset the switches.** Check them after every install — especially this
one.

## Manual registration instead

```json
{
  "mcpServers": {
    "Apple Mail": {
      "command": "/absolute/path/to/apple-mail-mcp/.build/release/apple-mail-mcp"
    }
  }
}
```

You lose the per-tool switches — including the one that disables sending. Do not do both
at once: two registrations under the same display name collide, and `mail_status` prints
the binary path precisely so you can tell which one answered.

## Implementation note: why the Apple events are in Objective-C

Every Apple event this project sends lives in the `MailBridge` target, written in
Objective-C. That is a correctness requirement, not taste.

Apple documents exactly one way to create a scriptable object: ask the application for the
class with `classForScriptingClass:`, `alloc`/`initWithProperties:` it, then insert it in
the container's element array. **That pattern cannot be written in Swift.** The class that
comes back is an `SBPseudoClass` — it inherits from `NSObject`, not `SBObject`, and turns
every class-level message into an `__NSMessageBuilder`, so a Swift metatype cast against it
aborts the process rather than returning nil. Underneath is a Swift limitation of long
standing: metadata symbols for ScriptingBridge classes do not exist at link time, because
the classes are made at runtime ([swiftlang/swift#43407][sr795], open since 2016).

In Objective-C none of it arises. A cast to a protocol is a compile-time annotation, the
documented creation pattern compiles as written, and there is no `unsafeBitCast` anywhere
in this repository.

[sr795]: https://github.com/swiftlang/swift/issues/43407

The bindings are hand-declared rather than generated: `sdef … | sdp -fh` emits a 637-line
header, while declaring the handful of members this server actually sends is smaller and
auditable. A selector Mail does not implement is a crash, not a nil — check `sdef` before
adding one.

One member is deliberately absent: Mail's `account` class exposes `password` in plain text.
It is declared nowhere, which makes it unreachable from this process. The narrow protocol
is the safeguard.

**Only Foundation types cross back into Swift.** No ScriptingBridge object escapes
`MailBridge.m`. Policy — which mailboxes to walk, how a query matches, where to stop, how
a result is shaped — stays in Swift, where the tests can reach it. The bridge is the part
no test can reach, so it is kept as thin as it can be.

Recipients, subject and body are passed as typed Apple event parameters, never interpolated
into script source — there is no script text to splice into, which is the whole reason
ScriptingBridge is used instead of `NSAppleScript`. Apple's own guidance is explicit on
that second point too: you should not use `NSAppleScript` merely to send an Apple event,
because it is far more expensive than ScriptingBridge.

## Known limits

- **Search matches sender and subject only**, not bodies. Body search would mean pulling
  every message across the event boundary.
- **A fixed scan ceiling per query**, 500 messages. When it bites, the result says so — a
  truncated answer is never presented as a complete one.
- **No attachments.** Reading or sending them is not exposed.
- **No reply threading.** Mail's `reply` command cannot be driven reliably with a
  caller-supplied body, so a reply would be composed as a new message; that is not wired
  up yet.

## Development

```bash
swift build
swift test
```

31 tests, all against an in-memory fake with Mail closed. Every fixture address uses the
reserved `.invalid` TLD, which can never resolve — so even a bug that reached the network
could not deliver anything. See `CLAUDE.md`, whose first section is the rule that makes
that non-negotiable.

Manual verification against a live mailbox is the owner's job; `verification.md` is
the script for it.

## Licence

MIT.
