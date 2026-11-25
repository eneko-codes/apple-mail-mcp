import Foundation
import Synchronization

/// Returns the first of two outcomes: the work finishing, or the limit passing.
///
/// The timer is a dispatch timer, not a `Task.sleep`, and the work is not a child of a task
/// group. An Apple event that Mail never answers holds its thread and cannot be cancelled,
/// and a task group would wait for it forever; a timer on the cooperative pool could be
/// starved by the same stuck threads. The stuck work is abandoned, not stopped: its late
/// result is discarded, and whatever it had asked Mail to do may still happen.
enum Deadline {

    private final class Outcome<Value: Sendable>: Sendable {
        private let continuation: Mutex<CheckedContinuation<Value?, Never>?>

        init(_ continuation: CheckedContinuation<Value?, Never>) {
            self.continuation = Mutex(continuation)
        }

        /// Only the first caller resumes; the other finds it empty.
        func resume(returning value: Value?) {
            continuation.withLock { pending in
                pending?.resume(returning: value)
                pending = nil
            }
        }
    }

    /// `nil` when `limit` passed before `work` finished.
    static func run<Value: Sendable>(
        within limit: Duration, _ work: @escaping @Sendable () async -> Value
    ) async -> Value? {
        let seconds = Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
        return await withCheckedContinuation { continuation in
            let outcome = Outcome<Value>(continuation)
            let task = Task {
                outcome.resume(returning: await work())
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                outcome.resume(returning: nil)
                task.cancel()
            }
        }
    }
}

/// Routes a `tools/call` to the store and renders the answer.
///
/// Never sends an Apple event itself — everything goes through `MailStore`, which is
/// what lets the tests drive every branch below with Mail closed and no mailbox
/// touched.
public struct MailTools: ToolHandler {
    private let store: any MailStore
    private let calendar: Calendar
    private let format: Format
    private let timeout: Duration

    public init(
        store: any MailStore, calendar: Calendar = .current,
        timeout: Duration = Configuration.callTimeLimit
    ) {
        self.store = store
        self.calendar = calendar
        self.format = Format(calendar: calendar)
        self.timeout = timeout
    }

    public func handle(_ parameters: ToolCall) async -> ToolOutput {
        let started = ContinuousClock.now
        let outcome = await Deadline.run(within: timeout) {
            do {
                return Result<String, any Error>.success(try await run(parameters))
            } catch {
                return .failure(error)
            }
        }
        switch outcome {
        case .success(let text)?:
            return ToolOutput(text: text, isError: false)
        case .failure(let error)?:
            return failure(error, tool: parameters.name, since: started)
        case nil:
            return failure(
                ToolError.timedOut(tool: parameters.name, seconds: Int(timeout.components.seconds)),
                tool: parameters.name, since: started)
        }
    }

    private func failure(
        _ error: any Error, tool: String, since started: ContinuousClock.Instant
    ) -> ToolOutput {
        Diagnostics.toolFailed(tool, error: error, since: started)
        let known = error as? ToolError ?? .storeFailure(error.localizedDescription)
        return ToolOutput(text: known.message, isError: true)
    }

    private func run(_ parameters: ToolCall) async throws -> String {
        let arguments = Arguments(parameters.arguments, calendar: calendar)

        // Reports availability instead of failing on it: this is the tool you reach for
        // precisely when the others are refusing to work.
        if parameters.name == ToolCatalog.statusName {
            return format.status(store.availability(), binaryPath: Self.binaryPath)
        }
        guard ToolCatalog.all().contains(where: { $0.name == parameters.name }) else {
            throw ToolError.unknownTool(parameters.name)
        }

        let state = store.availability()
        // A call whose consent has never been asked for still has to go through:
        // sending the Apple event is what raises the dialog.
        guard !state.blocksCalls else { throw ToolError.notAvailable(state) }

        switch parameters.name {
        case ToolCatalog.accountsName: return try await accounts(arguments)
        case ToolCatalog.searchName: return try await search(arguments)
        case ToolCatalog.getName: return try await get(arguments)
        case ToolCatalog.sendName: return try await send(arguments)
        default: throw ToolError.unknownTool(parameters.name)
        }
    }

    // MARK: Accounts

    private func accounts(_ arguments: Arguments) async throws -> String {
        let page = try arguments.page(
            defaultLimit: Configuration.accountLimit, limits: Configuration.accountLimitRange)
        let everyAccount = try await store.accounts()
        let rows = Self.accountRows(everyAccount)
        return ToolStandard.page(
            of: rows, limit: page.limit, offset: page.offset, things: "rows",
            notices: arguments.notices
        ) {
            format.accounts(
                rows: $0, accountCount: everyAccount.count,
                mailboxCount: everyAccount.reduce(0) { $0 + $1.mailboxes.count })
        }
    }

    /// "Archive 2" before "Archive 10", ignoring case: the order a page of names is given in.
    /// Names that differ only in case, or not at all, keep the order Mail listed them in.
    private static func sortedByName<Item>(_ items: [Item], _ name: (Item) -> String) -> [Item] {
        items.enumerated().sorted { lhs, rhs in
            let order = name(lhs.element).compare(name(rhs.element), options: [.caseInsensitive, .numeric])
            return order == .orderedSame ? lhs.offset < rhs.offset : order == .orderedAscending
        }.map(\.element)
    }

    /// Every account followed by its mailboxes, in the order `mail_accounts` states. An
    /// account with many addresses spreads them over several rows, so that no row grows
    /// with the data.
    static func accountRows(_ accounts: [AccountInfo]) -> [Format.AccountRow] {
        sortedByName(accounts, \.name).flatMap { account -> [Format.AccountRow] in
            let size = Configuration.addressesPerRow
            let later = stride(from: size, to: account.addresses.count, by: size).map {
                Format.AccountRow.addresses(
                    account: account.name, Array(account.addresses[$0...].prefix(size)))
            }
            return [.account(name: account.name, addresses: Array(account.addresses.prefix(size)))]
                + later
                + sortedByName(account.mailboxes, \.name).map {
                    .mailbox(account: account.name, name: $0.name, unreadCount: $0.unreadCount)
                }
        }
    }

    // MARK: Search

    /// What a search that stopped early tells the caller to narrow by.
    static let narrowingArguments = "account, mailbox, from_date or to_date"

    private func search(_ arguments: Arguments) async throws -> String {
        let query = try arguments.optionalString("query")
        let account = try arguments.optionalString("account")
        let mailbox = try arguments.optionalString("mailbox") ?? Configuration.defaultMailbox
        let from = try arguments.optionalDate("from_date")?.date
        // "On or before 12 August" has to include the whole of the 12th; a bare day
        // parses to midnight, which would exclude it.
        let to = try arguments.optionalDate("to_date").map { parsed in
            parsed.isDateOnly ? endOfDay(parsed.date) : parsed.date
        }
        if let from, let to, to < from {
            throw ToolError.datesOutOfOrder(
                from: try arguments.optionalString("from_date") ?? "",
                to: try arguments.optionalString("to_date") ?? "")
        }
        let unreadOnly = try arguments.bool("unread_only")
        let page = try arguments.page(
            defaultLimit: Configuration.searchLimit, limits: Configuration.searchLimitRange)

        let scan = try await store.search(
            query: query, account: account, mailbox: mailbox, from: from, to: to,
            unreadOnly: unreadOnly, scanCeiling: Configuration.scanCeiling,
            timeLimit: Configuration.scanTimeLimit)
        let matches = scan.matches.sorted(by: MailScan.precedes)

        // Echoing the scope back means a caller can see that its filters were understood
        // the way it meant them.
        var scope: [String] = []
        if let query { scope.append("'\(ToolStandard.echo(query))'") }
        if let mailbox { scope.append("in \(ToolStandard.echo(mailbox))") }
        if let account { scope.append("account \(ToolStandard.echo(account))") }
        if let from { scope.append("from \(format.stamp(from, withYear: true))") }
        if let to { scope.append("to \(format.stamp(to, withYear: true))") }
        if unreadOnly { scope.append("unread only") }
        let described = scope.isEmpty ? "all mail" : scope.joined(separator: " · ")

        // The messages never looked at count as not returned, so the reason the search
        // stopped goes before everything else it has to say.
        var notices = arguments.notices
        switch scan.stopped {
        case .scanCeiling?:
            notices.append(
                Notice.scanStopped(after: scan.scanned, things: "messages", narrowBy: Self.narrowingArguments))
        case .timeLimit?:
            notices.append(
                Notice.partial(after: scan.scanned, things: "messages", narrowBy: Self.narrowingArguments))
        case nil:
            break
        }

        // Not `ToolStandard.page`: which fields were clipped depends on the rows of the
        // page, so the notices are built for each size tried.
        return ToolStandard.fitting(page.limit) { size in
            let rows = Array(matches.dropFirst(page.offset).prefix(size))
            let position = Notice.page(
                offset: page.offset, count: rows.count, total: matches.count, things: "messages")
            return ToolStandard.withNotices(
                notices + Format.clipNotices(for: rows) + [position].compactMap { $0 },
                format.searchResults(rows: rows, scan: scan, describing: described))
        }
    }

    // MARK: One message

    private func get(_ arguments: Arguments) async throws -> String {
        let id = try arguments.messageID("id")
        let window = try arguments.window()
        guard let message = try await store.fetch(id: id) else {
            throw ToolError.notFound(id: id.encoded)
        }
        return ToolStandard.fitting(window.maxCharacters) {
            format.detail(
                message, characterOffset: window.characterOffset, maxCharacters: $0,
                notices: arguments.notices)
        }
    }

    // MARK: Send

    private func send(_ arguments: Arguments) async throws -> String {
        // Everything is validated before the confirm check so a caller that forgot the
        // flag still learns about a bad address in the same round trip.
        let to = try arguments.addresses("to", required: true)
        let cc = try arguments.addresses("cc", required: false)
        let bcc = try arguments.addresses("bcc", required: false)
        let subject = try arguments.requiredString("subject")
        let body = try arguments.requiredString("body")
        let from = try await resolvedSender(try arguments.optionalString("from"))

        guard try arguments.bool("confirm") else { throw ToolError.confirmationRequired }

        let draft = OutgoingDraft(
            to: to, cc: cc, bcc: bcc, subject: subject, body: body, from: from)
        return ToolStandard.withNotices(arguments.notices, format.sent(try await store.send(draft)))
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
