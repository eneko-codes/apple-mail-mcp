# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

No tool modifies, moves or deletes an existing message — a mailbox is a record. `send_mail` cannot be undone and needs owner confirmation before every send.

**Tests run against fakes** — in-memory doubles, fixtures, data invented for the test. Never the owner's real mailbox, and never out of convenience: the suite exists to catch breaking changes and does not need real data to do that.

**Debugging against live data is legitimate, but it is the owner's call, not yours.** Never decide it alone. Ask in chat as an explicit choice they can pick — not a remark inside a longer message — saying exactly what you will run, exactly which live data it would touch, and what it would create, change or delete and whether that is undoable. A yes covers that run only; a wider or different check needs a fresh question.

**A send is the one thing with no gentle route** — it either reaches a real address or it does not happen. So it needs the ask above every time, must be marked `TESTING: ...` in the subject, and must go only to the owner's own address. For everything else: read without writing first.

## What this is

A local MCP server (Swift 6, stdio transport) exposing the macOS Mail app via Apple events (`ScriptingBridge`, since Mail has no native framework for external readers). Mail must already be running; this server never launches it.

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
