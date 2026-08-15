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

    func search(
        query: String?, account: String?, mailbox: String?, from: Date?, to: Date?,
        unreadOnly: Bool, limit: Int, scanCeiling: Int
    ) async throws -> MessageSearchPage {
        // A real ceiling, so a test can exercise the truncation policy rather than
        // asserting that the formatter prints a flag someone set by hand.
        let scanned = messages.prefix(scanCeiling)
        let hitCeiling = messages.count > scanCeiling
        var matches = Array(scanned)
        if let account { matches = matches.filter { $0.account == account } }
        if let mailbox { matches = matches.filter { $0.mailbox == mailbox } }
        if let from { matches = matches.filter { $0.dateReceived >= from } }
        if let to { matches = matches.filter { $0.dateReceived <= to } }
        if unreadOnly { matches = matches.filter { !$0.isRead } }
        if let query, !query.isEmpty {
            matches = matches.filter {
                $0.subject.localizedCaseInsensitiveContains(query)
                    || $0.sender.localizedCaseInsensitiveContains(query)
            }
        }
        matches.sort { $0.dateReceived > $1.dateReceived }
        let page = matches.prefix(limit).map {
            MessageSummary(
                id: $0.id, subject: $0.subject, sender: $0.sender,
                dateReceived: $0.dateReceived, isRead: $0.isRead, mailbox: $0.mailbox)
        }
        return MessageSearchPage(
            results: Array(page), total: matches.count, hitScanLimit: hitCeiling)
    }

    func fetch(id: EmailID, bodyLimit: Int) async throws -> MessageDetail? {
        guard let found = messages.first(where: { $0.id == id }) else { return nil }
        let truncated = found.body.count > bodyLimit
        return MessageDetail(
            id: found.id, subject: found.subject, sender: found.sender,
            recipients: found.recipients, ccRecipients: found.ccRecipients,
            replyTo: found.replyTo, dateSent: found.dateSent,
            dateReceived: found.dateReceived, isRead: found.isRead, mailbox: found.mailbox,
            account: found.account, rfcMessageID: found.rfcMessageID,
            body: truncated ? String(found.body.prefix(bodyLimit)) : found.body,
            bodyTruncated: truncated)
    }

    func send(_ draft: OutgoingDraft) async throws -> SentReceipt {
        sent.append(draft)
        return SentReceipt(
            to: draft.to, cc: draft.cc, bcc: draft.bcc, subject: draft.subject,
            sender: "tester@example.invalid", bodyPreview: String(draft.body.prefix(280)))
    }
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
        body: String = "Invented body text."
    ) -> MessageDetail {
        MessageDetail(
            id: EmailID(account: account, mailbox: mailbox, messageID: id),
            subject: subject, sender: sender,
            recipients: ["tester@example.invalid"], ccRecipients: [], replyTo: nil,
            dateSent: received, dateReceived: received, isRead: isRead, mailbox: mailbox,
            account: account, rfcMessageID: "<\(id)@fictitious.invalid>", body: body,
            bodyTruncated: false)
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
