import Foundation

public enum MailMCPServer {

    public static let name = "apple-mail-mcp"
    public static let version = "2.0.0"

    /// Returned from `initialize`. It carries what per-tool descriptions cannot state
    /// once: that results come in pages and windows, and where a search stops.
    public static let instructions = """
        Access to the macOS Mail app.

        Workflow: mail_accounts to see what exists, mail_search to find messages, then \
        mail_get with the opaque id a search returned. Ids cannot be typed by hand.

        RESULTS COME IN PAGES. mail_search returns \(Configuration.searchLimit) messages \
        and mail_accounts \(Configuration.accountLimit) rows; mail_get returns the first \
        \(Configuration.defaultMaxCharacters) characters of a message's text. When more \
        exists than a result holds, its first lines say how much there is and the exact \
        argument that returns the rest: limit and offset for rows, character_offset and \
        max_characters for a message. A number outside its range is moved to the nearest \
        allowed value, and the first lines say which one was used. A wrong type, a date \
        that does not exist or a to_date before from_date is refused.

        Mail has no framework a separate process can use, so this server drives Mail.app \
        through Apple events. Mail must be running, and Mail — not this server — is what \
        reads the mailbox. That makes every query slow: always bound a search by account, \
        mailbox and date range (from_date and to_date, both inclusive).

        A SEARCH STOPS EARLY. One mail_search looks at no more than \
        \(Configuration.scanCeiling) messages across the mailboxes it opens, for no longer \
        than \(Configuration.scanTimeLimit.components.seconds) seconds. When it stops at \
        either, the first lines of the result say so; what it never looked at is not in \
        the result or its count, and only a narrower search reaches it. Any call that has \
        not finished after \(Configuration.callTimeLimit.components.seconds) seconds is \
        abandoned and answered with an error.

        This server can never delete, move or modify a received message. Mail's scripting \
        dictionary offers those commands; they are deliberately not exposed. A mailbox is \
        a record.

        send_mail is the one outward-facing tool and it CANNOT BE UNDONE — no recall, no \
        undo. It requires confirm=true. Show the recipients, subject and body to the \
        person and get their agreement first. If it ends with an error saying it ran out \
        of time, the message may still go out: never send it again without checking.

        What may be used at any moment is decided by the permission switches in the \
        client, not by this code.
        """

    /// The store is a parameter so the whole server can be driven by a double. Nothing
    /// in this function sends an Apple event by itself.
    public static func run(store: (any MailStore)? = nil) async {
        let store = store ?? ScriptingBridgeMailStore()
        Diagnostics.started(version: version)
        await serveStandardStreams(handler: handler(tools: MailTools(store: store)))
    }

    public static func handler(tools: MailTools) -> MCPHandler {
        MCPHandler(
            name: name, version: version, instructions: instructions,
            catalog: ToolCatalog.all(), tools: tools)
    }
}
