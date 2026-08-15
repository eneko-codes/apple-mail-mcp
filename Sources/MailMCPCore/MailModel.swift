import Foundation

/// Addresses one message.
///
/// Mail's `id` is an integer that is only unique *within a mailbox*, so locating a
/// message means knowing which mailbox to look in. The account is carried too because
/// two accounts routinely both have an "INBOX".
///
/// Encoded as base64url rather than a delimited string: mailbox and account names are
/// arbitrary user text and can contain any separator that might be chosen.
public struct EmailID: Sendable, Equatable, Hashable {
    public let account: String
    public let mailbox: String
    public let messageID: Int

    public init(account: String, mailbox: String, messageID: Int) {
        self.account = account
        self.mailbox = mailbox
        self.messageID = messageID
    }

    /// Unit separator: a control character that cannot occur in a mailbox name typed by
    /// a person, so the split is unambiguous before the base64 layer even matters.
    private static let separator = "\u{1F}"

    public var encoded: String {
        let joined = [account, mailbox, String(messageID)].joined(separator: Self.separator)
        return Data(joined.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ raw: String) -> EmailID? {
        var padded = raw.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }

        guard let data = Data(base64Encoded: padded),
            let text = String(data: data, encoding: .utf8)
        else { return nil }

        let parts = text.components(separatedBy: separator)
        guard parts.count == 3, let identifier = Int(parts[2]) else { return nil }
        return EmailID(account: parts[0], mailbox: parts[1], messageID: identifier)
    }
}

public struct AccountInfo: Sendable, Equatable {
    public let name: String
    public let addresses: [String]
    public let mailboxes: [MailboxInfo]

    public init(name: String, addresses: [String], mailboxes: [MailboxInfo]) {
        self.name = name
        self.addresses = addresses
        self.mailboxes = mailboxes
    }
}

public struct MailboxInfo: Sendable, Equatable {
    public let name: String
    public let unreadCount: Int

    public init(name: String, unreadCount: Int) {
        self.name = name
        self.unreadCount = unreadCount
    }
}

public struct MessageSummary: Sendable, Equatable {
    public let id: EmailID
    public let subject: String
    public let sender: String
    public let dateReceived: Date
    public let isRead: Bool
    public let mailbox: String

    public init(
        id: EmailID, subject: String, sender: String, dateReceived: Date, isRead: Bool,
        mailbox: String
    ) {
        self.id = id
        self.subject = subject
        self.sender = sender
        self.dateReceived = dateReceived
        self.isRead = isRead
        self.mailbox = mailbox
    }
}

public struct MessageDetail: Sendable, Equatable {
    public let id: EmailID
    public let subject: String
    public let sender: String
    public let recipients: [String]
    public let ccRecipients: [String]
    public let replyTo: String?
    public let dateSent: Date
    public let dateReceived: Date
    public let isRead: Bool
    public let mailbox: String
    public let account: String
    /// The RFC 5322 Message-ID. Stable across sessions, unlike the numeric id, so it is
    /// reported for reference even though addressing uses `EmailID`.
    public let rfcMessageID: String?
    public let body: String
    /// True when `body` was cut to the requested length, so the reader is never left to
    /// assume a truncated message is the whole thing.
    public let bodyTruncated: Bool

    public init(
        id: EmailID, subject: String, sender: String, recipients: [String],
        ccRecipients: [String], replyTo: String?, dateSent: Date, dateReceived: Date,
        isRead: Bool, mailbox: String, account: String, rfcMessageID: String?, body: String,
        bodyTruncated: Bool
    ) {
        self.id = id
        self.subject = subject
        self.sender = sender
        self.recipients = recipients
        self.ccRecipients = ccRecipients
        self.replyTo = replyTo
        self.dateSent = dateSent
        self.dateReceived = dateReceived
        self.isRead = isRead
        self.mailbox = mailbox
        self.account = account
        self.rfcMessageID = rfcMessageID
        self.body = body
        self.bodyTruncated = bodyTruncated
    }
}

public struct OutgoingDraft: Sendable, Equatable {
    public var to: [String]
    public var cc: [String]
    public var bcc: [String]
    public var subject: String
    public var body: String
    /// Which of the account's own addresses to send from. nil leaves the choice to
    /// Mail's default, which is the only behaviour there was before this existed — an
    /// account with several addresses would otherwise send from whichever one Mail
    /// happened to prefer, with no way to say so from the call.
    public var from: String?

    public init(
        to: [String], cc: [String] = [], bcc: [String] = [], subject: String, body: String,
        from: String? = nil
    ) {
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.from = from
    }
}

public struct SentReceipt: Sendable, Equatable {
    public let to: [String]
    public let cc: [String]
    public let bcc: [String]
    public let subject: String
    public let sender: String
    public let bodyPreview: String

    public init(
        to: [String], cc: [String], bcc: [String], subject: String, sender: String,
        bodyPreview: String
    ) {
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.sender = sender
        self.bodyPreview = bodyPreview
    }
}

public struct MessageSearchPage: Sendable, Equatable {
    public let results: [MessageSummary]
    public let total: Int
    /// True when the search stopped at a scan ceiling rather than exhausting the
    /// mailbox. Distinct from `total`: it means "there may be older matches I did not
    /// look at", which silence would misrepresent.
    public let hitScanLimit: Bool

    public init(results: [MessageSummary], total: Int, hitScanLimit: Bool = false) {
        self.results = results
        self.total = total
        self.hitScanLimit = hitScanLimit
    }
}
