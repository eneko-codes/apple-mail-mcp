import Foundation
import MCP

public enum MailMCPServer {

    public static let name = "apple-mail-mcp"
    public static let version = "1.0.0"

    public static let instructions = """
        Access to the macOS Mail app.

        Mail has no framework a separate process can use, so this server drives Mail.app \
        through Apple events. Mail must be running, and Mail — not this server — is what \
        reads the mailbox. That makes every query slow: always bound a search by mailbox \
        and date range. mail_search stops at a scan ceiling and says so when it does.

        Workflow: mail_accounts to see what exists, mail_search to find messages, then \
        mail_get with the opaque id a search returned. Ids cannot be typed by hand.

        This server can never delete, move or modify a received message. Mail's scripting \
        dictionary offers those commands; they are deliberately not exposed. A mailbox is \
        a record.

        send_mail is the one outward-facing tool and it CANNOT BE UNDONE — no recall, no \
        undo. It requires confirm=true. Show the recipients, subject and body to the \
        person and get their agreement first.

        What may be used at any moment is decided by the permission switches in the \
        client, not by this code.
        """

    /// The store is a parameter so the whole server can be driven by a double. Nothing
    /// in this function sends an Apple event by itself.
    public static func run(store: (any MailStore)? = nil) async throws {
        let store = store ?? ScriptingBridgeMailStore()
        let tools = MailTools(store: store)
        let server = Server(
            name: name,
            version: version,
            instructions: instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in .init(tools: ToolCatalog.all()) }
        await server.withMethodHandler(CallTool.self) { await tools.handle($0) }

        // The default StdioTransport logger is a no-op handler. Leave it that way: a
        // logger writing to stdout would interleave with the JSON-RPC stream and break
        // every response after the first log line.
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }
}
