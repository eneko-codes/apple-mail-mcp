# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

No tool modifies, moves, or deletes an existing message — a mailbox is a record. `send_mail` cannot be undone and needs owner confirmation before every send; test sends must be clearly marked `TESTING: ...` in the subject and go only to the owner's own address.

## What this is

A local MCP server (Swift 6, stdio transport) exposing the macOS Mail app via Apple events (`ScriptingBridge`, since Mail has no native framework for external readers). Mail must already be running; this server never launches it.

## Commands

```bash
swift build
swift build -c release
swift test
```

```bash
otool -P .build/release/apple-mail-mcp | grep NSAppleEventsUsageDescription
```
