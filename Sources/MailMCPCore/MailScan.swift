import Foundation

/// The policy of one search: which mailboxes to open, what matches, and where to stop.
///
/// It sends no Apple event. Reading a mailbox is a closure, so the real store hands in the
/// bridge and the tests hand in invented mailboxes, and both run the same rules.
public enum MailScan {

    /// One message as a mailbox walk reports it, before any filter but the dates.
    public struct Message: Sendable, Equatable {
        public var id: Int
        public var subject: String
        public var sender: String
        public var dateReceived: Date
        public var isRead: Bool

        public init(id: Int, subject: String, sender: String, dateReceived: Date, isRead: Bool) {
            self.id = id
            self.subject = subject
            self.sender = sender
            self.dateReceived = dateReceived
            self.isRead = isRead
        }
    }

    /// What walking one mailbox returned.
    public struct Mailbox: Sendable, Equatable {
        /// The messages looked at, at most as many as were allowed.
        public var messages: [Message]
        /// The walk was allowed no more messages and the mailbox still held some.
        public var reachedMaximum: Bool
        /// The walk ran out of time before the end of the mailbox.
        public var ranOutOfTime: Bool

        public init(messages: [Message], reachedMaximum: Bool = false, ranOutOfTime: Bool = false) {
            self.messages = messages
            self.reachedMaximum = reachedMaximum
            self.ranOutOfTime = ranOutOfTime
        }
    }

    /// Opens the mailboxes that `account` and `mailbox` select, in the order `accounts`
    /// lists them, until they are all read, `scanCeiling` messages have been looked at or
    /// `isPastDeadline` answers true.
    ///
    /// The ceiling is spent across mailboxes, not per mailbox: a walk that stopped early in
    /// one must not get a fresh budget in the next, or the advertised bound would mean
    /// nothing. A mailbox never opened counts as stopped, because it may hold matches.
    public static func run(
        accounts: [AccountInfo], query: String?, account: String?, mailbox: String?,
        unreadOnly: Bool, scanCeiling: Int, isPastDeadline: () -> Bool,
        walk: (_ account: String, _ mailbox: String, _ maximum: Int) throws -> Mailbox
    ) rethrows -> MessageScan {
        let selected = accounts.filter { account == nil || $0.name == account }.flatMap { entry in
            entry.mailboxes.filter { box in
                mailbox.map { box.name.localizedCaseInsensitiveCompare($0) == .orderedSame } ?? true
            }.map { (account: entry.name, mailbox: $0.name) }
        }

        var matches: [MessageSummary] = []
        var scanned = 0
        var opened = 0
        var stopped: MessageScan.Stop?

        for target in selected {
            if scanned >= scanCeiling {
                stopped = .scanCeiling
                break
            }
            if isPastDeadline() {
                stopped = .timeLimit
                break
            }
            let walked = try walk(target.account, target.mailbox, scanCeiling - scanned)
            opened += 1
            scanned += walked.messages.count

            for message in walked.messages {
                if unreadOnly && message.isRead { continue }
                if let query, !query.isEmpty,
                    !message.subject.localizedCaseInsensitiveContains(query),
                    !message.sender.localizedCaseInsensitiveContains(query)
                { continue }
                matches.append(
                    MessageSummary(
                        id: EmailID(account: target.account, mailbox: target.mailbox, messageID: message.id),
                        subject: message.subject.isEmpty ? "(no subject)" : message.subject,
                        sender: message.sender, dateReceived: message.dateReceived,
                        isRead: message.isRead, mailbox: target.mailbox))
            }

            if walked.ranOutOfTime {
                stopped = .timeLimit
                break
            }
            if walked.reachedMaximum {
                stopped = .scanCeiling
                break
            }
        }
        return MessageScan(
            matches: matches, scanned: scanned, stopped: stopped, mailboxesOpened: opened,
            mailboxesSelected: selected.count)
    }

    /// Newest first. Two messages received in the same second are told apart by account,
    /// mailbox and Mail's own id, so the order has no ties and a page boundary falls in the
    /// same place on the next call.
    public static func precedes(_ lhs: MessageSummary, _ rhs: MessageSummary) -> Bool {
        if lhs.dateReceived != rhs.dateReceived { return lhs.dateReceived > rhs.dateReceived }
        return (lhs.id.account, lhs.id.mailbox, lhs.id.messageID)
            < (rhs.id.account, rhs.id.mailbox, rhs.id.messageID)
    }
}
