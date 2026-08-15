import Foundation
import MCP

/// Routes a `tools/call` to the store and renders the answer.
///
/// Never sends an Apple event itself — everything goes through `MailStore`, which is
/// what lets the tests drive every branch below with Mail closed and no mailbox
/// touched.
public struct MailTools: Sendable {
    private let store: any MailStore
    private let calendar: Calendar
    private let format: Format

    public init(store: any MailStore, calendar: Calendar = .current) {
        self.store = store
        self.calendar = calendar
        self.format = Format(calendar: calendar)
    }

    public func handle(_ parameters: CallTool.Parameters) async -> CallTool.Result {
        do {
            let text = try await run(parameters)
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        } catch let error as ToolError {
            return .init(
                content: [.text(text: error.message, annotations: nil, _meta: nil)], isError: true)
        } catch {
            return .init(
                content: [
                    .text(
                        text: ToolError.storeFailure(error.localizedDescription).message,
                        annotations: nil, _meta: nil)
                ], isError: true)
        }
    }

    private func run(_ parameters: CallTool.Parameters) async throws -> String {
        let arguments = Arguments(parameters.arguments, calendar: calendar)

        // Reports availability instead of failing on it: this is the tool you reach for
        // precisely when the others are refusing to work.
        if parameters.name == ToolCatalog.statusName {
            return format.status(store.availability(), binaryPath: Self.binaryPath)
        }

        let state = store.availability()
        // A call whose consent has never been asked for still has to go through:
        // sending the Apple event is what raises the dialog.
        guard !state.blocksCalls else { throw ToolError.notAvailable(state) }

        switch parameters.name {
        case ToolCatalog.accountsName:
            return format.accounts(try await store.accounts())

        case ToolCatalog.searchName:
            return try await search(arguments)

        case ToolCatalog.getName:
            let id = try arguments.messageID("id")
            let bodyLimit = try arguments.int(
                "body_limit", default: Configuration.bodyLimit, in: Configuration.bodyLimitRange)
            guard let message = try await store.fetch(id: id, bodyLimit: bodyLimit) else {
                throw ToolError.notFound(id: id.encoded)
            }
            return format.detail(message)

        case ToolCatalog.sendName:
            return try await send(arguments)

        default:
            throw ToolError.badArgument(
                name: "name", reason: "'\(parameters.name)' is not a tool of this server")
        }
    }

    private func search(_ arguments: Arguments) async throws -> String {
        let query = arguments.optionalString("query")
        let account = arguments.optionalString("account")
        // The fixed default is what keeps an unbounded search from crawling every
        // mailbox of every account.
        let mailbox = arguments.optionalString("mailbox") ?? Configuration.defaultMailbox
        let from = try arguments.optionalDate("from_date")?.date
        // "On or before 12 August" has to include the whole of the 12th; a bare day
        // parses to midnight, which would exclude it.
        let to = try arguments.optionalDate("to_date").map { parsed in
            parsed.isDateOnly ? endOfDay(parsed.date) : parsed.date
        }
        let limit = try arguments.int(
            "limit", default: Configuration.searchLimit, in: Configuration.searchLimitRange)

        let page = try await store.search(
            query: query, account: account, mailbox: mailbox, from: from, to: to,
            unreadOnly: arguments.bool("unread_only"), limit: limit,
            scanCeiling: Configuration.scanCeiling)

        // Echoing the scope back means a caller can see that its filters were understood
        // the way it meant them.
        var scope: [String] = []
        if let query { scope.append("'\(query)'") }
        if let mailbox { scope.append("in \(mailbox)") }
        if let account { scope.append("account \(account)") }
        if let from { scope.append("from \(format.stamp(from, withYear: true))") }
        if let to { scope.append("to \(format.stamp(to, withYear: true))") }
        if arguments.bool("unread_only") { scope.append("unread only") }
        return format.searchResults(
            page, describing: scope.isEmpty ? "all mail" : scope.joined(separator: " · "))
    }

    private func send(_ arguments: Arguments) async throws -> String {
        // Everything is validated before the confirm check so a caller that forgot the
        // flag still learns about a bad address in the same round trip.
        let to = try arguments.addresses("to", required: true)
        let cc = try arguments.addresses("cc", required: false)
        let bcc = try arguments.addresses("bcc", required: false)
        let subject = try arguments.requiredString("subject")
        let body = try arguments.requiredString("body")
        let from = try await resolvedSender(arguments.optionalString("from"))

        guard arguments.bool("confirm") else { throw ToolError.confirmationRequired }

        let draft = OutgoingDraft(
            to: to, cc: cc, bcc: bcc, subject: subject, body: body, from: from)
        return format.sent(try await store.send(draft))
    }

    /// Checks `from` against the addresses Mail actually owns, and returns it in the
    /// spelling Mail knows it by.
    ///
    /// Mail accepts an unknown `sender` without complaint and quietly sends from the
    /// default account instead, so an unvalidated typo produces a message that went out
    /// under the wrong identity and reported success. Matching case-insensitively and
    /// returning the stored spelling also means a caller need not reproduce the account's
    /// own capitalisation.
    private func resolvedSender(_ requested: String?) async throws -> String? {
        guard let requested, !requested.isEmpty else { return nil }
        let known = try await store.accounts().flatMap(\.addresses)
        guard
            let match = known.first(where: { $0.caseInsensitiveCompare(requested) == .orderedSame })
        else {
            throw ToolError.unknownSender(requested, known: known)
        }
        return match
    }

    private func endOfDay(_ date: Date) -> Date {
        let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
        return (next ?? date).addingTimeInterval(-1)
    }

    static var binaryPath: String {
        CommandLine.arguments.first.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? "(unknown)"
    }
}
