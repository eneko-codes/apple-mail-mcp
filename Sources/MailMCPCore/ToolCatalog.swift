import Foundation
import MCP

/// The catalogue is the authorisation surface: a tool that is not listed here cannot be
/// called, and the name it is listed under is the label on the permission switch in
/// Claude Desktop. Reads carry no verb prefix; the one write starts with `send_`.
///
/// Mail's dictionary also exposes `delete`, `move`, `bounce` and `redirect`. None of
/// them is listed here, and none should be: a received message is a record, and this
/// server does not rewrite records.
public enum ToolCatalog {

    /// Names are constants rather than being read back off a `Tool`, because a tool
    /// whose schema depends on the configuration has to be built as a function and its
    /// name would then have nowhere stable to live.
    public static let statusName = "mail_status"
    public static let accountsName = "mail_accounts"
    public static let searchName = "mail_search"
    public static let getName = "mail_get"
    public static let sendName = "send_mail"

    public static func all() -> [Tool] { [status, accounts, search, get, send] }

    // MARK: Schema helpers

    private static func object(properties: [String: Value], required: [String] = []) -> Value {
        var schema: [String: Value] = [
            "type": .string("object"), "properties": .object(properties),
        ]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        schema["additionalProperties"] = .bool(false)
        return .object(schema)
    }

    private static func string(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func stringArray(_ description: String) -> Value {
        .object([
            "type": .string("array"), "items": .object(["type": .string("string")]),
            "description": .string(description),
        ])
    }

    private static func integer(_ description: String, minimum: Int, maximum: Int, default def: Int)
        -> Value
    {
        .object([
            "type": .string("integer"), "description": .string(description),
            "minimum": .int(minimum), "maximum": .int(maximum), "default": .int(def),
        ])
    }

    private static let dateHelp =
        "Accepts 2026-08-12, 2026-08-12T09:00, or 2026-08-12T09:00:00+02:00."

    // MARK: Reads

    static let status = Tool(
        name: statusName,
        title: "Mail availability and permission",
        description: """
            Reports whether Mail is running and whether this server may control it, and \
            says exactly what to enable and where if not. Reads no mail.

            It checks the permission without sending a real Apple event, so it is safe to \
            call first when anything else is failing. Use it before assuming a mail tool \
            is broken.
            """,
        inputSchema: object(properties: [:]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let accounts = Tool(
        name: accountsName,
        title: "List mail accounts and mailboxes",
        description: """
            Lists every configured account with its addresses and mailboxes, and the \
            unread count per mailbox.

            Call this before mail_search when you need to narrow a query: searching a \
            single mailbox is far faster than searching all of them. Reads no message \
            content.
            """,
        inputSchema: object(properties: [:]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let search = Tool(
        name: searchName,
        title: "Search mail",
        description: """
            Finds messages by sender or subject, optionally bounded by account, mailbox \
            and date. Returns one line per hit with an opaque id, newest first.

            ALWAYS bound the query. This works by asking Mail to walk a mailbox, which is \
            slow: without a date range or a specific mailbox, a large account will take a \
            very long time. The search stops after \(Configuration.scanCeiling) messages \
            and says so when it does, so a narrow query is not just faster, it is more \
            complete.

            It matches sender and subject only, not message bodies.
            """,
        inputSchema: object(properties: [
            "query": string("Text to match against sender and subject."),
            "account": string("Restrict to one account, exactly as mail_accounts names it."),
            "mailbox": string("Restrict to one mailbox, for example \"INBOX\"."),
            "from_date": string("Only messages received on or after this. \(dateHelp)"),
            "to_date": string("Only messages received on or before this. \(dateHelp)"),
            "unread_only": .object([
                "type": .string("boolean"), "default": .bool(false),
                "description": .string("Only unread messages."),
            ]),
            "limit": integer(
                "Maximum number of messages to return.",
                minimum: Configuration.searchLimitRange.lowerBound,
                maximum: Configuration.searchLimitRange.upperBound,
                default: Configuration.searchLimit),
        ]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let get = Tool(
        name: getName,
        title: "Read one message",
        description: """
            Returns the headers and body of a single message.

            Needs an id from mail_search; ids are opaque and cannot be typed by hand. The \
            body is truncated at 'body_limit' characters and says so when it is, so a \
            short result is never mistaken for a short email.

            Reading a message here does not mark it as read.
            """,
        inputSchema: object(
            properties: [
                "id": string("Identifier returned by mail_search."),
                "body_limit": integer(
                    "Maximum characters of body to return.",
                    minimum: Configuration.bodyLimitRange.lowerBound,
                    maximum: Configuration.bodyLimitRange.upperBound,
                    default: Configuration.bodyLimit),
            ],
            required: ["id"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    // MARK: Write

    static let send = Tool(
        name: sendName,
        title: "Send an email",
        description: """
            Sends an email from the Mail app. Requires confirm=true.

            THIS CANNOT BE UNDONE. There is no recall, no undo and no draft to fall back \
            on; the message leaves the machine immediately. Show the recipients, subject \
            and body to the person and get their agreement before calling with \
            confirm=true.

            Check the addresses character by character first — a typo sends someone else's \
            information to a stranger, and that cannot be taken back. Use bcc, not cc, \
            when recipients should not see each other.

            One account can own several addresses. Omitting 'from' lets Mail pick its \
            default, which may not be the one the person means; call mail_accounts and \
            pass 'from' explicitly when it matters who the message appears to come from.
            """,
        inputSchema: object(
            properties: [
                "from": string(
                    """
                    Send from this address. Must be one of this Mail installation's own \
                    addresses, as listed by mail_accounts. Omit to use Mail's default.
                    """),
                "to": stringArray("Recipient addresses. At least one is required."),
                "cc": stringArray("Cc addresses. Everyone can see these."),
                "bcc": stringArray("Bcc addresses. Hidden from other recipients."),
                "subject": string("Subject line."),
                "body": string("Plain-text body."),
                "confirm": .object([
                    "type": .string("boolean"),
                    "description": .string(
                        "Must be true. Without it nothing is sent."),
                ]),
            ],
            required: ["to", "subject", "body", "confirm"]),
        annotations: .init(
            readOnlyHint: false,
            // Not "destructive" in the delete sense, but it is irreversible and
            // outward-facing, which is the property a client should surface.
            destructiveHint: true,
            idempotentHint: false,
            openWorldHint: true)
    )
}
