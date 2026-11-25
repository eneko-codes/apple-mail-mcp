import Foundation

/// Plain-text rendering of every tool result.
public struct Format: Sendable {
    let calendar: Calendar

    public init(calendar: Calendar) {
        self.calendar = calendar
    }

    // MARK: Helpers

    static func pad(_ text: String, to width: Int) -> String {
        let shortfall = width - text.count
        return shortfall > 0 ? text + String(repeating: " ", count: shortfall) : text
    }

    static func clip(_ text: String, to width: Int) -> String {
        guard text.count > width else { return text }
        return String(text.prefix(width - 1)) + "…"
    }

    static func block(_ rows: [(String, String?)]) -> String {
        let present = rows.compactMap { label, value -> (String, String)? in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return (label, value)
        }
        guard let width = present.map(\.0.count).max() else { return "" }
        let indent = String(repeating: " ", count: width + 3)
        return present.map { label, value in
            let wrapped = value.split(separator: "\n", omittingEmptySubsequences: false)
                .joined(separator: "\n" + indent)
            return "  \(pad(label, to: width)) \(wrapped)"
        }.joined(separator: "\n")
    }

    /// Collapses a multi-line value onto one line, so the one-row-per-item contract that
    /// makes a listing scannable survives a subject containing a newline.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : (noun.hasSuffix("x") ? "es" : "s"))"
    }

    /// What an empty page says when the offset skipped every row.
    static let nothingAtThisOffset = "(nothing at this offset)"

    private static let months = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    /// Hand-rolled so output does not change shape with the machine's locale.
    func stamp(_ date: Date, withYear: Bool = false) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let month = parts.month.map { Self.months[($0 - 1) % 12] } ?? "???"
        let base = String(format: "%02d %@", parts.day ?? 0, month)
        let time = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        return withYear ? "\(base) \(parts.year ?? 0), \(time)" : "\(base) \(time)"
    }

    // MARK: Accounts

    /// One row of `mail_accounts`: an account with its first addresses, more of its
    /// addresses, or one of its mailboxes.
    public enum AccountRow: Sendable, Equatable {
        case account(name: String, addresses: [String])
        case addresses(account: String, [String])
        case mailbox(account: String, name: String, unreadCount: Int)
    }

    /// `rows` is the page to show; the counts are of everything Mail has.
    public func accounts(rows: [AccountRow], accountCount: Int, mailboxCount: Int) -> String {
        guard accountCount > 0 else { return "No mail accounts configured." }
        var lines = [
            "\(Self.plural(accountCount, "account")), \(Self.plural(mailboxCount, "mailbox")), "
                + "ordered by account name, then mailbox name. Pass 'account' and 'mailbox' to "
                + "mail_search to narrow a query."
        ]
        guard !rows.isEmpty else {
            return lines[0] + "\n\n  " + Self.nothingAtThisOffset
        }
        lines.append("")

        // Wide enough for the names on this page, but one very long name must not push
        // every unread count off to the right.
        let width = min(
            rows.map { row -> Int in
                if case .mailbox(_, let name, _) = row { return name.count }
                return 0
            }.max() ?? 0, 40)
        var current: String?
        // A page that starts part-way through an account still says whose rows these are.
        func continuing(_ account: String) {
            guard current != account else { return }
            current = account
            lines.append("\(Self.oneLine(account)) (continued)")
        }
        func listed(_ addresses: [String]) -> String {
            "<" + addresses.map(Self.oneLine).joined(separator: ", ") + ">"
        }
        for row in rows {
            switch row {
            case .account(let name, let addresses):
                current = name
                lines.append(Self.oneLine(name) + (addresses.isEmpty ? "" : "  " + listed(addresses)))
            case .addresses(let account, let addresses):
                continuing(account)
                lines.append("  more addresses  " + listed(addresses))
            case .mailbox(let account, let name, let unreadCount):
                continuing(account)
                // Padded only when a count follows, so no line ends in spaces.
                lines.append(
                    "    "
                        + (unreadCount > 0
                            ? Self.pad(Self.oneLine(name), to: width) + "  \(unreadCount) unread"
                            : Self.oneLine(name)))
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Search

    /// The sentences for the fields `searchResults` shortened in `rows`, if any.
    static func clipNotices(for rows: [MessageSummary]) -> [String] {
        var notices: [String] = []
        if rows.contains(where: { oneLine($0.sender).count > Configuration.senderWidth }) {
            notices.append(
                Notice.clipped(field: "Sender", width: Configuration.senderWidth, tool: ToolCatalog.getName))
        }
        if rows.contains(where: { oneLine($0.subject).count > Configuration.subjectWidth }) {
            notices.append(
                Notice.clipped(field: "Subject", width: Configuration.subjectWidth, tool: ToolCatalog.getName))
        }
        return notices
    }

    /// `rows` is the page to show; `scan` is the whole search it was taken from.
    public func searchResults(rows: [MessageSummary], scan: MessageScan, describing scope: String) -> String {
        guard scan.mailboxesSelected > 0 else {
            return """
                No mailbox matches \(scope). mail_accounts lists the accounts and mailboxes \
                that exist; 'account' must be written exactly as it is listed there.
                """
        }
        let reach =
            "Looked at \(Self.plural(scan.scanned, "message")) in \(scan.mailboxesOpened) of "
            + "\(Self.plural(scan.mailboxesSelected, "mailbox"))."
        guard !scan.matches.isEmpty else { return "No messages match \(scope). \(reach)" }

        var lines = [
            "\(Self.plural(scan.matches.count, "message")) · \(scope)",
            "Newest first; • marks unread. \(reach)",
        ]
        guard !rows.isEmpty else {
            return lines.joined(separator: "\n") + "\n\n  " + Self.nothingAtThisOffset
        }
        lines.append("")

        let dateWidth = rows.map { stamp($0.dateReceived, withYear: true).count }.max() ?? 0
        let senderWidth = min(
            rows.map { Self.oneLine($0.sender).count }.max() ?? 0, Configuration.senderWidth)
        for message in rows {
            var line = message.isRead ? "   " : "•  "
            line += Self.pad(stamp(message.dateReceived, withYear: true), to: dateWidth)
            line += "  " + Self.pad(Self.clip(Self.oneLine(message.sender), to: senderWidth), to: senderWidth)
            line += "  " + Self.clip(Self.oneLine(message.subject), to: Configuration.subjectWidth)
            line += "  [\(Self.oneLine(message.mailbox))]"
            lines.append(line + "  id=\(message.id.encoded)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: One message

    /// The part of a message that `mail_get` returns through a window: the subject, the
    /// headers (from, to, cc, reply-to, message-id) and the body. All of it is the message's own text, which never
    /// changes, so a window taken later starts exactly where an earlier one ended.
    static func messageText(_ message: MessageDetail) -> String {
        message.subject + "\n"
            + block([
                ("from", message.sender),
                ("to", message.recipients.joined(separator: ", ")),
                ("cc", message.ccRecipients.joined(separator: ", ")),
                ("reply-to", message.replyTo),
                ("message-id", message.rfcMessageID),
            ]) + "\n\n" + message.body
    }

    /// The facts about the message come first and are always whole: they are short, and
    /// one of them (read or not) can change between two calls. Then the window.
    public func detail(
        _ message: MessageDetail, characterOffset: Int, maxCharacters: Int, notices: [String]
    ) -> String {
        let whole = Self.messageText(message)
        let window = ToolStandard.window(
            of: whole, characterOffset: characterOffset, maxCharacters: maxCharacters,
            label: "Message text")
        var text = "Message\n"
        text += Self.block([
            ("id", message.id.encoded),
            ("mailbox", "\(Self.oneLine(message.account)) / \(Self.oneLine(message.mailbox))"),
            ("sent", stamp(message.dateSent, withYear: true)),
            ("received", stamp(message.dateReceived, withYear: true)),
            ("read", message.isRead ? "yes" : "no"),
            ("text", "\(whole.count) characters of subject, headers and body"),
        ])
        text += "\n\n" + window.text
        return ToolStandard.withNotices(notices + [window.notice].compactMap { $0 }, text)
    }

    // MARK: Send

    /// The first addresses of one list as the receipt shows them, and what to say if that
    /// is not all of them.
    private static func receiptAddresses(_ addresses: [String], field: String) -> (shown: String?, note: String?) {
        guard !addresses.isEmpty else { return (nil, nil) }
        let shown = addresses.prefix(Configuration.receiptAddressCount)
            .map { ToolStandard.echo(oneLine($0)) }.joined(separator: ", ")
        guard addresses.count > Configuration.receiptAddressCount else { return (shown, nil) }
        return (
            shown,
            "\(field): the first \(Configuration.receiptAddressCount) of \(addresses.count) addresses "
                + "are shown. The message went to all \(addresses.count)."
        )
    }

    /// `length` is that of the text as it was sent, which for a subject shown on one line
    /// is not always the length of `text`.
    private static func receiptExcerpt(_ text: String, field: String, width: Int, length: Int) -> (shown: String, note: String?) {
        guard text.count > width else { return (text, nil) }
        return (
            String(text.prefix(width)),
            "\(field): the first \(width) of \(length) characters are shown. All of it was sent."
        )
    }

    /// The receipt is the only record the caller gets of something that cannot be undone,
    /// so it names every list the message went to, including bcc. It repeats the caller's
    /// own text only in part, and says so before the data whenever a part is not the whole.
    public func sent(_ receipt: SentReceipt) -> String {
        let to = Self.receiptAddresses(receipt.to, field: "to")
        let cc = Self.receiptAddresses(receipt.cc, field: "cc")
        let bcc = Self.receiptAddresses(receipt.bcc, field: "bcc")
        let subject = Self.receiptExcerpt(
            Self.oneLine(receipt.subject), field: "subject", width: Configuration.receiptSubjectWidth,
            length: receipt.subject.count)
        let body = Self.receiptExcerpt(
            receipt.body, field: "body", width: Configuration.receiptBodyWidth, length: receipt.body.count)

        var notes = [to.note, cc.note, bcc.note, subject.note, body.note].compactMap { $0 }
        if (receipt.to + receipt.cc + receipt.bcc).contains(where: { $0.count > ToolStandard.echoWidth }) {
            notes.append(
                "Addresses longer than \(ToolStandard.echoWidth) characters are shortened here. Each was used whole.")
        }

        var text = (["Sent. This cannot be recalled."] + notes).joined(separator: "\n") + "\n\n"
        text += Self.block([
            ("from", Self.oneLine(receipt.sender)),
            ("to", to.shown), ("cc", cc.shown), ("bcc", bcc.shown),
            ("subject", subject.shown),
            ("body", "\(receipt.body.count) characters"),
        ])
        return text + "\n\n" + body.shown
    }

    // MARK: Status

    public func status(_ state: MailAvailability, binaryPath: String) -> String {
        let headline: String
        switch state {
        case .ready: headline = "Mail: RUNNING, automation permitted."
        case .notInstalled: headline = "Mail: NOT INSTALLED."
        case .notRunning: headline = "Mail: NOT RUNNING."
        case .automationDenied: headline = "Mail automation: DENIED."
        case .consentNotGranted: headline = "Mail automation: not requested yet."
        }

        var text = headline + "\n\n"
        // The fixed sizes: naming them here is the only way to see them, now that there is
        // no settings form to read them back from.
        text += Self.block([
            ("binary", binaryPath),
            ("target", ScriptingBridgeMailStore.bundleIdentifier),
            ("process", "pid \(ProcessInfo.processInfo.processIdentifier)"),
            ("default mailbox", Configuration.defaultMailbox ?? "none (searches every mailbox)"),
            (
                "one search",
                "looks at up to \(Configuration.scanCeiling) messages for up to "
                    + "\(Configuration.scanTimeLimit.components.seconds) seconds"
            ),
            (
                "search page",
                "\(Configuration.searchLimit) messages, up to \(Configuration.searchLimitRange.upperBound)"
            ),
            (
                "accounts page",
                "\(Configuration.accountLimit) rows, up to \(Configuration.accountLimitRange.upperBound)"
            ),
            (
                "message window",
                "\(Configuration.defaultMaxCharacters) characters, up to "
                    + "\(Configuration.maxCharactersRange.upperBound)"
            ),
            ("call time limit", "\(Configuration.callTimeLimit.components.seconds) seconds"),
        ])
        if state != .ready {
            text += "\n\n" + ToolError.availabilityMessage(state)
        }
        return text
    }
}
