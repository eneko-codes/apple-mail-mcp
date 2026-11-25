import Foundation

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

    /// A `default` is advertised only where omitting the argument really means that value.
    private static func integer(_ description: String, range: ClosedRange<Int>, default def: Int)
        -> Value
    {
        .object([
            "type": .string("integer"), "description": .string(description),
            "minimum": .int(range.lowerBound), "maximum": .int(range.upperBound),
            "default": .int(def),
        ])
    }

    private static func boolean(_ description: String, default def: Bool? = nil) -> Value {
        var schema: [String: Value] = [
            "type": .string("boolean"), "description": .string(description),
        ]
        if let def { schema["default"] = .bool(def) }
        return .object(schema)
    }

    private static func limit(_ things: String, range: ClosedRange<Int>, default def: Int) -> Value {
        integer("Maximum number of \(things) in one page.", range: range, default: def)
    }

    private static let offset = integer(
        """
        Number of rows to skip. A result that does not hold every row says, in its first \
        lines, the offset to pass for the next page.
        """, range: Configuration.offsetRange, default: 0)

    private static let dateHelp =
        "Accepts \(Arguments.dateForms); the first two are local time."

    private static let readOnly = Tool.Annotations(
        readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)

    // MARK: Reads

    static let status = Tool(
        name: statusName,
        title: "Mail availability and permission",
        description: """
            Reports whether Mail is running and whether this server may control it, and \
            says exactly what to enable and where if not. Also lists the fixed sizes this \
            server works to. Reads no mail, and its result is always short.

            It checks the permission without sending a real Apple event, so it is safe to \
            call first when anything else is failing. Use it before assuming a mail tool \
            is broken.
            """,
        inputSchema: object(properties: [:]),
        annotations: readOnly)

    static let accounts = Tool(
        name: accountsName,
        title: "List mail accounts and mailboxes",
        description: """
            Lists the mail accounts with their addresses, each followed by its mailboxes \
            and their unread counts: \(Configuration.accountLimit) rows to a page, ordered \
            by account name, then mailbox name. A mailbox is one row and so is an account, \
            which takes a further row for every \(Configuration.addressesPerRow) addresses \
            past its first \(Configuration.addressesPerRow). When there are more rows than \
            the page holds, the first lines of the result say how many there are and the \
            offset of the next page: pass limit (up to \
            \(Configuration.accountLimitRange.upperBound)) and offset.

            Call this before mail_search when you need to narrow a query: searching a \
            single mailbox is far faster than searching all of them. Reads no message \
            content.
            """,
        inputSchema: object(properties: [
            "limit": limit(
                "rows", range: Configuration.accountLimitRange,
                default: Configuration.accountLimit),
            "offset": offset,
        ]),
        annotations: readOnly)

    static let search = Tool(
        name: searchName,
        title: "Search mail",
        description: """
            Finds messages by sender or subject and returns \(Configuration.searchLimit) to \
            a page, newest first, one line each: date received, sender, subject, mailbox and \
            an opaque id for mail_get. Sender is clipped to \(Configuration.senderWidth) \
            characters and subject to \(Configuration.subjectWidth); bodies are not searched \
            and not returned. When more match than the page holds, the first lines of the \
            result say how many there are and the offset of the next page: pass limit (up \
            to \(Configuration.searchLimitRange.upperBound)) and offset.

            ALWAYS bound the query with account, mailbox, from_date and to_date. This \
            works by asking Mail to walk mailboxes, which is slow, and one search looks at \
            no more than \(Configuration.scanCeiling) messages in all, for no longer than \
            \(Configuration.scanTimeLimit.components.seconds) seconds. When it stops at \
            either, the first lines say so: messages it never looked at are not in the \
            result or its count, mailboxes later in the list may not have been opened at \
            all, and the only way to reach them is a narrower call.

            from_date and to_date are both inclusive, and one alone runs to the end. \
            Every page walks the mailboxes again, so ask for a larger limit before asking \
            for many pages.
            """,
        inputSchema: object(properties: [
            "query": string("Text to match against sender and subject, ignoring case."),
            "account": string("Restrict to one account, exactly as mail_accounts names it."),
            "mailbox": string("Restrict to mailboxes of this name, ignoring case, for example \"INBOX\"."),
            "from_date": string("Only messages received on or after this. \(dateHelp)"),
            "to_date": string(
                "Only messages received on or before this; a bare day includes all of that day. \(dateHelp)"),
            "unread_only": boolean("Only unread messages.", default: false),
            "limit": limit(
                "messages", range: Configuration.searchLimitRange, default: Configuration.searchLimit),
            "offset": offset,
        ]),
        annotations: readOnly)

    static let get = Tool(
        name: getName,
        title: "Read one message",
        description: """
            Returns one message: its id, mailbox, dates and read state, then its text, \
            which is the subject, sender, to and cc recipients, reply-to, message-id and \
            plain-text body. With no optional argument the first \(Configuration.defaultMaxCharacters) \
            characters of that text are returned, which is all of most messages. When it \
            is longer, the first lines of the result say how long it is and the \
            character_offset to pass for the rest: read on with character_offset and \
            max_characters (up to \(Configuration.maxCharactersRange.upperBound)).

            Needs an id from mail_search; ids are opaque and cannot be typed by hand. \
            Attachments are not returned. Reading a message here does not mark it as read.
            """,
        inputSchema: object(
            properties: [
                "id": string("Identifier returned by mail_search."),
                "character_offset": integer(
                    """
                    Number of characters of the message text to skip. A result that does \
                    not hold all of it says, in its first lines, the value to pass for the \
                    rest.
                    """, range: Configuration.characterOffsetRange, default: 0),
                "max_characters": integer(
                    "The most characters of the message text to return.",
                    range: Configuration.maxCharactersRange,
                    default: Configuration.defaultMaxCharacters),
            ],
            required: ["id"]),
        annotations: readOnly)

    // MARK: Write

    static let send = Tool(
        name: sendName,
        title: "Send an email",
        description: """
            Sends an email from the Mail app and returns a short receipt: the sender, \
            every recipient list including bcc, the subject and the start of the body. \
            Requires confirm=true.

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

            The receipt shows the first \(Configuration.receiptBodyWidth) characters of the \
            body and the first \(Configuration.receiptAddressCount) addresses of each list, \
            and says so when that is not all of them; the message itself is always sent \
            whole. If Mail has not answered after \
            \(Configuration.callTimeLimit.components.seconds) seconds the call ends with an \
            error saying the message may still go out: do not send it again without \
            checking.
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
                "confirm": boolean("Must be true. Without it nothing is sent."),
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
