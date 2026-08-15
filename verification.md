# Manual verification

Everything below runs against **your real mailbox**, which is why no agent may run it
(see the hard rule in `CLAUDE.md`). Work through it yourself, in order.

```bash
npx @modelcontextprotocol/inspector ./.build/release/apple-mail-mcp
```

## 0 — Before you start

You need a **second address you control** for the send tests — a secondary account, an
alias, anything that is not a stranger. Never test `send_mail` against someone else.

Note the exact name of one account and one mailbox from Mail.app's sidebar; steps 3
onwards need them spelled exactly as Mail has them.

## 1 — Permission plumbing

| Step | Call | Expected |
|---|---|---|
| 1.1 | Quit Mail, then `mail_status` | `Mail: NOT RUNNING`, and the explanation that this server will not launch it. |
| 1.2 | Open Mail, then `mail_status` | Either `not requested yet` or `RUNNING, automation permitted`. **No dialog should have appeared yet** — status asks TCC directly. |
| 1.3 | `mail_accounts` | *"apple-mail-mcp wants to control Mail"* appears. Approve. |
| 1.4 | `mail_status` | `RUNNING, automation permitted`. |
| 1.5 | Deny the grant in System Settings → Automation, restart Claude Desktop, `mail_status` | `DENIED`, with the exact settings path. Re-enable afterwards. |

Step 1.2 is the one worth confirming: if a dialog appears there, the permission check is
sending a real event when it should not be.

## 2 — Accounts

| Step | Call | Expected |
|---|---|---|
| 2.1 | `mail_accounts` | Every account, its addresses, its mailboxes, unread counts. |
| 2.2 | Compare against Mail.app's sidebar | Same names, same unread numbers. |
| 2.3 | Check the output | **No password appears anywhere.** Mail's dictionary exposes one; this server must never surface it. |

## 3 — Search

Start narrow. A first call with no bounds on a large account can take minutes.

| Step | Call | Expected |
|---|---|---|
| 3.1 | `mail_search {"mailbox":"INBOX","limit":5}` | Five newest, unread marked with `•`, each with `id=`. |
| 3.2 | Time it | Note how long. Compare with 3.3. |
| 3.3 | Same plus `"from_date"` for the last week | Noticeably faster — the date bound is pushed into Mail as a `whose` clause. |
| 3.4 | `{"query":"<a sender you know>"}` | Matches on sender. |
| 3.5 | `{"query":"<a word that appears only in a body>"}` | **No match** — search covers sender and subject only, by design. |
| 3.6 | `{"unread_only":true}` | Only unread. Cross-check the count against Mail.app. |
| 3.7 | `{"from_date":"last Tuesday"}` | Refused, listing the accepted forms. |
| 3.8 | Search a very large mailbox with no date bound | Either results, or the `⚠ Scan limit reached` warning. It must never silently return a partial answer as if complete. |

## 4 — Read

| Step | Call | Expected |
|---|---|---|
| 4.1 | `mail_get` with an id from 3.1 | Headers plus body. Compare against Mail.app. |
| 4.2 | Check the message in Mail.app afterwards | **Still unread** if it was unread. Reading here must not change its state. |
| 4.3 | `mail_get` on a long email with `"body_limit":500` | Body cut, with `[Body truncated…]`. |
| 4.4 | `mail_get {"id":"INBOX-1"}` | Refused: ids are opaque, not hand-typed. |
| 4.5 | Move a message in Mail.app, then `mail_get` its old id | Refused, explaining ids do not survive a move. |
| 4.6 | `mail_get` on an HTML-only email | Readable text, not markup or an empty body. |

Step 4.6 is the one most likely to disappoint: `content` is rich text, and how
ScriptingBridge hands it over is the least certain part of this server.

## 5 — Send

**Every step here sends real email. Use only your own second address.**

| Step | Call | Expected |
|---|---|---|
| 5.1 | `send_mail` without `confirm` | Refused, explaining there is no recall. **Check the outbox: nothing sent, no draft.** |
| 5.2 | `send_mail {"to":["Aurora Fakeperson"], …, "confirm":true}` | Refused: not an address. Nothing sent. |
| 5.3 | `send_mail {"to":[], …, "confirm":true}` | Refused: needs a recipient. |
| 5.4 | A bad address **and** no `confirm` | The address error is reported — validation runs first, so you do not fix one problem and then meet the other. |
| 5.5 | `"from"` set to an address Mail does not own | Refused, listing your real addresses. Nothing sent — Mail would otherwise substitute the default account silently. |
| 5.6 | `"from"` set to one of your own addresses, in the wrong case | Arrives from that address; the receipt names it in Mail's spelling, not yours. |
| 5.7 | `send_mail` to your second address, `"confirm":true` | Arrives. Receipt says `Sent. This cannot be recalled.` |
| 5.8 | Same with a `bcc` to a third address you own | Receipt lists the bcc. Confirm the `to` recipient's copy does **not** show it. |
| 5.9 | Subject containing `"` and `'` and a newline in the body | Arrives intact — proof that nothing is being spliced into script source. |
| 5.10 | Wait a minute, then check Mail.app's Sent mailbox | The messages are there. |

Step 5.9 is the injection check. If the subject arrives mangled or the send fails, the
parameter-passing path is wrong.

Step 5.10 says "wait a minute" for a reason. **Mail leaves a copy in Drafts even when the
send succeeded**, and Sent Messages takes about a minute to catch up over iCloud — so a
mailbox read taken immediately after a successful send looks exactly like a failed one.
Read Sent Messages, not Drafts, and read it late. Getting this backwards is how a working
send gets diagnosed as broken.

## 6 — The mailbox is a record

| Step | Check | Expected |
|---|---|---|
| 6.1 | `tools/list` | Exactly five tools. No `delete`, `move`, `bounce` or `redirect`. |
| 6.2 | Ask Claude to delete or archive an email | It should find no tool for it. |

## 7 — Restart behaviour

| Step | Action | Expected |
|---|---|---|
| 7.1 | Restart Claude Desktop, `mail_status` | Still permitted, no second prompt. |
| 7.2 | `swift build -c release`, restart, `mail_status` | With ad-hoc signing, prompts again — the cdhash changed. |
| 7.3 | Quit Mail mid-session, call `mail_search` | `NOT RUNNING`, cleanly. No hang, no crash. |

## Clean up

Delete the test emails from both accounts. Record the date and macOS version you
verified on, and the Mail version (`mail_status` does not report it; Mail → About).
