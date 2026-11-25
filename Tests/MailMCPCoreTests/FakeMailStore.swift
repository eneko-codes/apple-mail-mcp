import Foundation

@testable import MailMCPCore

/// In-memory `MailStore` for the tests.
///
/// Every fixture here is invented and every address uses the reserved `.invalid` TLD,
/// which can never resolve — so even a bug that reached the network could not deliver
/// anything. The test suite must never reach a real mailbox: see the hard rule in
/// CLAUDE.md.
final class FakeMailStore: MailStore, @unchecked Sendable {
    var state: MailAvailability
    var accountList: [AccountInfo]
    var messages: [MessageDetail]
    /// Everything `send` was asked to deliver. A test asserting this is empty is
    /// asserting that nothing left the machine.
    private(set) var sent: [OutgoingDraft] = []
    /// When set, a search runs out of time once it has looked at this many messages.
    var timeRunsOutAfter: Int?
    /// When set, `fetch` and `send` take this long, as Mail does when it is not answering.
    var delay: Duration?

    init(
        state: MailAvailability = .ready,
        accounts: [AccountInfo] = Fixtures.accounts,
        messages: [MessageDetail] = Fixtures.messages
    ) {
        self.state = state
        self.accountList = accounts
        self.messages = messages
    }

    func availability() -> MailAvailability { state }

    func accounts() async throws -> [AccountInfo] { accountList }

    /// Runs the real policy, `MailScan`, over the invented mailboxes: the ceiling, the time
    /// limit and the matching a test sees are the ones the server ships.
    func search(
        query: String?, account: String?, mailbox: String?, from: Date?, to: Date?,
        unreadOnly: Bool, scanCeiling: Int, timeLimit: Duration
    ) async throws -> MessageScan {
        var looked = 0
        return MailScan.run(
            accounts: accountList, query: query, account: account, mailbox: mailbox,
            unreadOnly: unreadOnly, scanCeiling: scanCeiling,
            isPastDeadline: { self.timeRunsOutAfter.map { looked >= $0 } ?? false }
        ) { accountName, mailboxName, maximum in
            // The date bound is applied by Mail itself, before anything is counted.
            let held = messages.filter { message in
                message.account == accountName && message.mailbox == mailboxName
                    && message.dateReceived >= (from ?? .distantPast)
                    && message.dateReceived <= (to ?? .distantFuture)
            }
            var allowed = min(held.count, maximum)
            var ranOutOfTime = false
            if let budget = timeRunsOutAfter, looked + allowed > budget {
                allowed = max(budget - looked, 0)
                ranOutOfTime = true
            }
            looked += allowed
            return MailScan.Mailbox(
                messages: held.prefix(allowed).map {
                    MailScan.Message(
                        id: $0.id.messageID, subject: $0.subject, sender: $0.sender,
                        dateReceived: $0.dateReceived, isRead: $0.isRead)
                },
                reachedMaximum: !ranOutOfTime && held.count > maximum, ranOutOfTime: ranOutOfTime)
        }
    }

    func fetch(id: EmailID) async throws -> MessageDetail? {
        if let delay { try? await Task.sleep(for: delay) }
        return messages.first { $0.id == id }
    }

    func send(_ draft: OutgoingDraft) async throws -> SentReceipt {
        if let delay { try? await Task.sleep(for: delay) }
        sent.append(draft)
        return SentReceipt(
            to: draft.to, cc: draft.cc, bcc: draft.bcc, subject: draft.subject,
            sender: "tester@example.invalid", body: draft.body)
    }
}

/// What a test reads back from one `tools/call`.
struct ToolResult {
    var text: String
    var isError: Bool
}

/// One call through the tool layer, against a fake.
func call(
    _ name: String, _ arguments: [String: Value] = [:], store: FakeMailStore = FakeMailStore(),
    timeout: Duration = Configuration.callTimeLimit
) async -> ToolResult {
    let tools = MailTools(store: store, calendar: Fixtures.calendar, timeout: timeout)
    let result = await tools.handle(.init(name: name, arguments: arguments))
    return ToolResult(text: result.text, isError: result.isError)
}

enum Fixtures {
    static let timeZone = TimeZone(identifier: "Europe/Madrid")!

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0)
        -> Date
    {
        calendar.date(
            from: DateComponents(
                timeZone: timeZone, year: year, month: month, day: day, hour: hour, minute: minute)
        )!
    }

    static let accounts: [AccountInfo] = [
        AccountInfo(
            name: "Personal", addresses: ["tester@example.invalid"],
            mailboxes: [
                MailboxInfo(name: "INBOX", unreadCount: 2),
                MailboxInfo(name: "Sent", unreadCount: 0),
            ]),
        AccountInfo(
            name: "Work", addresses: ["tester@fictitious.invalid"],
            mailboxes: [MailboxInfo(name: "INBOX", unreadCount: 0)]),
    ]

    static func message(
        account: String = "Personal",
        mailbox: String = "INBOX",
        id: Int,
        subject: String,
        sender: String,
        received: Date,
        isRead: Bool = true,
        recipients: [String] = ["tester@example.invalid"],
        body: String = "Invented body text."
    ) -> MessageDetail {
        MessageDetail(
            id: EmailID(account: account, mailbox: mailbox, messageID: id),
            subject: subject, sender: sender,
            recipients: recipients, ccRecipients: [], replyTo: nil,
            dateSent: received, dateReceived: received, isRead: isRead, mailbox: mailbox,
            account: account, rfcMessageID: "<\(id)@fictitious.invalid>", body: body)
    }

    /// More than the fixed scan ceiling, so the truncation policy is reachable from a
    /// test without any flag to turn the ceiling down.
    static var manyMessages: [MessageDetail] {
        (1...(Configuration.scanCeiling + 5)).map {
            message(
                id: 1000 + $0, subject: "Bulk \($0)", sender: "bulk@fictitious.invalid",
                received: date(2026, 8, 1, 9, 0))
        }
    }

    static let messages: [MessageDetail] = [
        message(
            id: 101, subject: "Invoice for July", sender: "billing@fictitious.invalid",
            received: date(2026, 8, 3, 9, 15), isRead: false,
            body: String(repeating: "Long body. ", count: 200)),
        message(
            id: 102, subject: "Lunch on Friday?", sender: "Aurora <aurora@madeup.invalid>",
            received: date(2026, 8, 7, 13, 0), isRead: false),
        message(
            account: "Work", id: 201, subject: "Quarterly review agenda",
            sender: "basil@fictitious.invalid", received: date(2026, 8, 8, 8, 30)),
    ]
}
