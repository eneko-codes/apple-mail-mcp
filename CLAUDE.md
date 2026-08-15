# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## HARD RULE — THE OWNER'S MAILBOX IS A RECORD, AND SENDING CANNOT BE UNDONE

**A received message is never to be modified, moved or deleted**, and **no message is
ever to be sent to anyone but the owner**. This rule outranks every other instruction in
this file, in every session, with no "just this once".

Never:

- modify, move or delete any message — the tools do not expose it, and neither should a
  raw Apple event or a hand-written AppleScript;
- send to a third party. Not a colleague, not a test service, not an address the owner
  pasted into the conversation for some other purpose;
- read `~/Library/Mail` directly;
- read real messages to "see what the shape is" — the fixtures show the shape.

**One narrow exception, granted by the owner.** A **test message may be sent to the
owner's own address**, and nowhere else, provided that:

- the subject says plainly that it is a test from this project;
- the owner is told, before the send, what is going out;
- exactly one is sent — a retry after an unclear failure needs the mailbox checked first,
  not a second copy.

Two things make this exception sharper than the ones in the sibling repositories. A sent
message **cannot be cleaned up**: there is no delete here, so the mistake is permanent in
a way a stray test contact never is. And a failed send is not necessarily a clean one —
observed live, an Apple event that timed out left a fully composed **draft** behind while
reporting nothing but "AppleEvent timed out". After any failed send, check Drafts and
tell the owner what is sitting there; the owner removes it, not you.

Reading the mailbox afterwards needs care in both directions. A successful send *also*
leaves a copy in Drafts, and Sent Messages takes about a minute to catch up over iCloud,
so a check run immediately looks exactly like a failure. Wait, then look at Sent
Messages — not at Drafts.

`send_mail` remains the only outward-facing tool in the project, and the only one whose
mistakes cannot be walked back.

**Fixtures first, always.** `FakeMailStore` drives the whole tool layer; every address in
the suite uses the reserved `.invalid` TLD, which can never resolve, so nothing can leave
the machine by accident. Reach for a live send only for what the fake cannot reach — the
Apple events themselves, in `MailBridge`, below the `MailStore` seam.

Allowed without asking, because none of it touches mail data:

| Action | Why it is safe |
|---|---|
| `swift build`, `swift test` | Tests run against the in-memory fake |
| `initialize`, `tools/list` over stdio | Protocol only; Mail is never contacted |
| `sdef /System/Applications/Mail.app` | Reads the app bundle, not the mailbox |
| `otool -P` on the built binary | Inspects the embedded Info.plist |

Full verification against a real mailbox remains the **owner's** job, by hand, with MCP
Inspector. `verification.md` is the script for it. The single-test-send exception
above is for proving one specific below-the-seam behaviour, not for running that script.

## Language

**Everything in this repository is written in English** — code, comments, tool
descriptions, error messages, documentation and commit messages. The one exception is
literal macOS UI strings quoted inside permission instructions, which must match what
is on screen (for example the System Settings pane name in the user's locale).

## What this is

A local MCP server (Swift 6, stdio transport) exposing the macOS Mail app.

**There is no native framework for Mail.** MailKit exists but only builds extensions
that run *inside* Mail; an external process cannot use it to read a mailbox. The only
route is Apple events, and Apple's recommended way to send them from Cocoa is
`ScriptingBridge.framework`, which is what this server uses. Mail must be running, and
Mail — not this process — is what reads the mailbox.

## Commands

```bash
swift build
swift build -c release
swift test
```

Inspect what Mail actually exposes to scripting (reads the app bundle, not mail):

```bash
sdef /System/Applications/Mail.app | grep -E '<(class|command) '
```

```bash
otool -P .build/release/apple-mail-mcp | grep NSAppleEventsUsageDescription
```

## Architecture

`Sources/MailMCPCore` holds everything; `Sources/apple-mail-mcp/main.swift` is a
launcher.

**`MailStore` is the seam.** Dispatch, formatting and argument decoding never send an
Apple event — they go through the protocol, so the tool layer is fully testable against
`FakeMailStore`. Only `ScriptingBridgeMailStore` talks to Mail.

**Every Apple event this project sends lives in the `MailBridge` Objective-C target.**
That is a correctness requirement, not a preference.

Apple documents exactly one way to create a scriptable object: ask the application for
the class with `classForScriptingClass:`, `alloc`/`initWithProperties:` it, then insert
it in the container's element array. That pattern **cannot be written in Swift**. The
class that comes back is an `SBPseudoClass` — it inherits from `NSObject`, not
`SBObject`, and turns every class-level message into an `__NSMessageBuilder`, so
`as? SBObject.Type` fails for every scripting class and even a plain Swift `as?` against
it aborts the process, because the cast is itself a message send. Underneath is a Swift
limitation of long standing: the metadata symbols for Scripting Bridge classes do not
exist at link time because the classes are made at runtime (swiftlang/swift#43407, open
since 2016).

In Objective-C none of it arises. A cast to a protocol is a compile-time annotation, the
documented creation pattern compiles as written, and there is no `unsafeBitCast`
anywhere in this repository. Verified live: the bridge composes and sends, and returns
the resolved sender.

The bindings are hand-declared rather than generated. `sdef | sdp -fh` emits a 637-line
header; declaring the handful of members this server actually sends is smaller and
auditable. Check `sdef` before adding one — a selector Mail does not implement is a
crash, not a nil.

**Do not reach for `NSAppleScript`.** Apple's own guide is explicit: "You should not use
NSAppleScript to execute a script merely to result in sending an Apple event, because it
is far more expensive than using Scripting Bridge or creating and sending an Apple event
directly." This project did exactly that for a while, after wrongly concluding Scripting
Bridge could not create objects. It can; only Swift cannot ask it to.

**Only Foundation types cross back into Swift.** No Scripting Bridge object escapes
`MailBridge.m`. Policy — which mailboxes to walk, how a query matches, where to stop
scanning, how a result is shaped — stays in Swift, where `FakeMailStore` can reach it.
The bridge is the part no test can, so it is kept as thin as it can be.

**An object is not viable until it is added to its container.** Scripting Bridge:
"you cannot set or access its properties until it's been added". So `sendMessageFrom:`
creates the message, inserts it in `outgoingMessages`, and only then sets the sender and
the recipients. Setting them earlier is the kind of mistake that half-works.

## Invariants worth protecting

- **Never delete, move or modify a received message.** Mail's dictionary exposes
  `delete` and `move`; this server must not surface them. A mailbox is evidence.
- **`send_mail` is the only outward-facing tool.** It cannot be undone. It must state
  in its own description that there is no recall.
- **Bound every query by date and count.** AppleScript over a large mailbox is very
  slow; an unbounded search will appear to hang. `limit` and a date range are not
  optional conveniences.
- **Never interpolate caller strings into script source.** Everything crosses as a
  typed Apple event parameter through Scripting Bridge — there is no script text to
  splice into, which is the whole reason Scripting Bridge is used here. A subject line
  full of quotes is data, and a test sends exactly that.
- **`send_mail` is verified end to end, from inside the server.** One real send through
  the installed extension returned immediately with the resolved sender, and the message
  landed in Sent Messages and was delivered. That is the run that matters: the previous
  `NSAppleScript` path composed and then hung in exactly this context while working fine
  from a shell, so a standalone binary proves nothing on its own.
- **Mail keeps a copy in Drafts even after a successful send.** Observed on every
  successful send: the message appears in Drafts *and* Sent Messages. A draft is
  therefore not evidence that a send failed, and the mailbox has to be read a minute
  later, once iCloud has synchronised, before drawing any conclusion. Reading Drafts too
  early is how a working send gets mistaken for a broken one.
- **Isolate one variable at a time when testing against a live app.** The old send path
  was blamed on the `visible` flag by a comparison that changed two things at once —
  osascript *and* `visible:true` against the server *and* `visible:false`. The wrong
  conclusion reached a commit before the controls were run. One variable per run, and the
  controls before the conclusion.
- **`from` is checked against the addresses Mail owns.** Mail accepts an unknown `sender`
  without complaint and quietly sends from the default account instead, so an unvalidated
  typo produces a message that went out under the wrong identity and reported success.
  `Dispatch.resolvedSender` refuses it and lists the real addresses.
- **No property may declare a union `type`.** Claude Desktop's schema sanitiser drops such
  a property and hands the model a bare `{}`; an array argument is then serialised to a
  string. Found in the sibling contacts server. A test walks the catalogue to keep unions
  out of this one.
- **Mail must be running.** If it is not, say so and stop; launching an app on the
  owner's behalf is a side effect they did not ask for. `availability()` therefore checks
  `isRunning` **before** consent: consent stays pending until the first Apple event, and
  that event would launch Mail.
- **A pending consent must not block a call.** macOS only shows the Automation dialog
  when a real Apple event is sent, so refusing on `.consentNotGranted` means the dialog
  never appears and the permission can never be granted. That is why `blocksCalls` asks
  whether a call may proceed rather than whether Mail is ready — the two are not the same
  question, and only one of them may gate a call. Observed live.
- **stdout carries JSON-RPC and nothing else.**

## Packaging as a Claude extension

`extension/manifest.json` plus `scripts/pack.sh` produce `dist/apple-mail-mcp.mcpb`,
a zip with `manifest.json` at its root. `server.type` is `"binary"` — no Node, no Python,
just the Swift binary.

**The `tools` array is what creates the per-tool switches.** Claude Desktop lists and
toggles tools from the manifest, before the server has ever run. A tool missing from that
array has no switch. Keep it in step with `ToolCatalog`.

There is no `user_config` and `mcp_config.args` is empty: every former setting — default
mailbox, scan ceiling, body limit, search limit — is now a constant in `Configuration`,
per the owner's plug-and-play rule. The only place left for a person to change this
server's behaviour is the per-tool permission switch.

`pack.sh` checks everything here that fails silently otherwise: that the embedded
`Info.plist` survived both linking and signing, that the signature is not `linker-signed`,
that a designated requirement exists at all, and that the executable bit survived the zip.
The MCPB spec does not promise the installer preserves file modes; if a future Claude
release drops it, the symptom is a server that never starts and the fix is `chmod +x` on
the installed copy under `~/Library/Application Support/Claude/Claude Extensions/`.

## TCC notes

Claude Desktop spawns MCP servers through `Contents/Helpers/disclaimer`, which calls
`responsibility_spawnattrs_setdisclaim`. The child is therefore **its own TCC subject**.
Sending Apple events needs `NSAppleEventsUsageDescription` in the embedded
`Resources/Info.plist`; the key name was verified against the `tccd` binary.

The permission appears under System Settings → Privacy & Security → **Automation**, as
`apple-mail-mcp` wanting to control `Mail`. It is a per-target grant: controlling Mail
says nothing about controlling any other app.

**A linker-signed binary gets no TCC prompt at all.** `swift build` leaves exactly that,
and it produces no designated requirement, so nothing is ever logged and the status stays
"not determined". `pack.sh` re-signs and prints the requirement; if that line is empty the
build is broken in a way nothing else will show.
