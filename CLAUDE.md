# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

No tool modifies, moves or deletes an existing message — a mailbox is a record. `send_mail` cannot be undone and needs owner confirmation before every send.

**Tests run against fakes** — in-memory doubles, fixtures, data invented for the test. Never the owner's real mailbox, and never out of convenience: the suite exists to catch breaking changes and does not need real data to do that.

**Debugging against live data is legitimate, but it is the owner's call, not yours.** Never decide it alone. Ask in chat as an explicit choice they can pick — not a remark inside a longer message — saying exactly what you will run, exactly which live data it would touch, and what it would create, change or delete and whether that is undoable. A yes covers that run only; a wider or different check needs a fresh question.

**A send is the one thing with no gentle route** — it either reaches a real address or it does not happen. So it needs the ask above every time, must be marked `TESTING: ...` in the subject, and must go only to the owner's own address. For everything else: read without writing first.

## What this is

A local MCP server (Swift 6, stdio transport) exposing the macOS Mail app via Apple events (`ScriptingBridge`, since Mail has no native framework for external readers). Mail must already be running; this server never launches it. There is **no third-party dependency**: `Package.swift` lists none, and the MCP protocol (JSON-RPC over stdio) is `MCPServer.swift` over Foundation. Adding a package needs the owner's say-so.

**`MCPServer.swift`, `Value.swift`, `ToolStandard.swift` and the tests `MCPProtocolTests.swift` and `ToolStandardTests.swift` are copied unchanged into every one of the owner's MCP servers** (the test files differ only in their `@testable import`). A change to one is made to every copy in the same piece of work; never let a copy drift.

`ToolStandard.swift` holds what every tool here must keep to: the longest result, description and error, the time a call may take, the fixed wording of each notice that says what a result left out (`Notice`), and the guard `MCPServer.swift` passes every result through. A tool bounds its own result and says how to get the rest; the guard only catches the one that forgot.

## Apple technology

Mail ships no framework an external process can use — MailKit only builds extensions that run inside Mail — so everything is an Apple event. [ScriptingBridge](https://developer.apple.com/documentation/scriptingbridge) — `SBApplication`, `SBElementArray` — for every read and write; `AEDeterminePermissionToAutomateTarget` ([Apple Events](https://developer.apple.com/documentation/coreservices/apple_events)) to check consent without sending an event; [AppKit](https://developer.apple.com/documentation/appkit) `NSWorkspace`/`NSRunningApplication` to see whether the app is there and running. Consent key: [`NSAppleEventsUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription).

## Native surface not used

`sdef /System/Applications/Mail.app` is the authority on what is possible here. Check it before proposing a tool.

- `delete`, `move`, `bounce`, `redirect`, `forward`, `reply` — deliberately not exposed; a test enforces their absence.
- `rule`, `rule condition` — no mail rule is read or written.
- `signature`, `message viewer`, `check for new mail`, `synchronize`, `import Mail mailbox`.
- Mailbox creation: the dictionary has `mailbox`, but no tool here makes one.

## Commands

```bash
swift build
swift build -c release
swift test
```

```bash
otool -P .build/release/apple-mail-mcp | grep NSAppleEventsUsageDescription
```

## Architecture

**Apple silicon only, deliberately.** `scripts/pack.sh` builds for arm64 alone — a plain `swift build -c release`, no `--arch` flags — and fails if the binary
holds any other architecture. A universal build doubles the bundle for an architecture
macOS 26 is the last release to support. Do not add an x86_64 slice back.

**How a tool keeps to the tool standard here.** Sizes, ranges, defaults and times are constants in `Configuration`, and the schemas, the descriptions, the instructions and `mail_status` quote them by interpolation, never as literals. `Arguments.int` moves a quantity (`limit`, `offset`, a window) into its range and collects the sentence that says so in `notices`; a wrong type, a date that does not exist and a `to_date` before `from_date` are refused. `mail_accounts` sorts its rows and goes through `ToolStandard.page`. `mail_search` gets every match among the messages looked at from the store, sorts them newest first with no ties (`MailScan.precedes`) and pages them itself with `Notice.page`, because the notices for clipped fields depend on the rows of the page; a search that stopped at the scan ceiling or ran out of time says so first (`Notice.scanStopped`, `Notice.partial`). `mail_get` windows the message's own text (`Format.messageText`: subject, from, to, cc, reply-to, message-id, body) with `ToolStandard.window`. Everything renders through `ToolStandard.fitting`, so a tool never leans on the guard. `BoundsTests` holds every bound, notice and length to this: a new listing takes `limit` and `offset` through `Arguments.page` and gets an entry in its `listings`.

**The policy of a search is `MailScan`, and it sends no Apple event.** Which mailboxes to open, what matches and where to stop are decided there; reading one mailbox is a closure. `ScriptingBridgeMailStore` hands in the bridge and `FakeMailStore` hands in invented mailboxes, so the tests run the rules that ship.

**Time.** `MailTools.handle` abandons any call at `Configuration.callTimeLimit` and answers with an error; the Apple event it was waiting on cannot be cancelled and may still complete, which is why the error for `send_mail` says the message may still go out. A search also carries `Configuration.scanTimeLimit` into the bridge, which checks it before each message and returns what it has. Neither can interrupt one Apple event already sent.

## Release checklist

- **Bump the version before packing.** Three files carry it and must agree: `extension/manifest.json`, `MailMCPServer.version` in `Server.swift`, and `CFBundleShortVersionString` in `Resources/Info.plist`. A renamed or removed argument is a major version.
- **The text the model reads is code.** Update the server `instructions`, tool and argument descriptions, the manifest `tools` and `long_description` and `README.md` in the same commit as the behaviour.

## Diagnostics

Logs go to stderr through `Diagnostics`, which the host captures (Claude Desktop writes it to `~/Library/Logs/Claude/mcp-server-<name>.log`). stdout is the JSON-RPC stream: never `print`. The API takes no free-form text on purpose. Do not add one, and do not log an argument, a result, an error's `localizedDescription` or an identifier; log a fixed event, the tool name, the error's kind and a duration.
