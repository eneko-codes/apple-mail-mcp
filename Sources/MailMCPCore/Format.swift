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

    // MARK: Tools

    public func accounts(_ accounts: [AccountInfo]) -> String {
        guard !accounts.isEmpty else { return "No mail accounts configured." }
        var lines: [String] = []
        for account in accounts {
            var header = account.name
            if !account.addresses.isEmpty {
                header += "  <" + account.addresses.joined(separator: ", ") + ">"
            }
            lines.append(header)
            let width = account.mailboxes.map(\.name.count).max() ?? 0
            for mailbox in account.mailboxes {
                var line = "    " + Self.pad(mailbox.name, to: width)
                if mailbox.unreadCount > 0 { line += "  \(mailbox.unreadCount) unread" }
                lines.append(line)
            }
        }
        lines.append("")
        lines.append("Pass 'account' and 'mailbox' to mail_search to narrow a query.")
        return lines.joined(separator: "\n")
    }

    public func searchResults(_ page: MessageSearchPage, describing scope: String) -> String {
        guard !page.results.isEmpty else {
            var text = "No messages match \(scope)."
            if page.hitScanLimit {
                text +=
                    "\n\nThe scan limit was reached before the mailbox was exhausted, so older"
                    + "\nmatches may exist. Narrow the date range and try again."
            }
            return text
        }

        let dateWidth = page.results.map { stamp($0.dateReceived).count }.max() ?? 0
        let senderWidth = min(page.results.map(\.sender.count).max() ?? 0, 32)

        var lines = ["\(page.total) message\(page.total == 1 ? "" : "s") · \(scope)"]
        for message in page.results {
            var line = message.isRead ? "   " : "•  "
            line += Self.pad(stamp(message.dateReceived), to: dateWidth)
            line += "  " + Self.pad(Self.clip(message.sender, to: senderWidth), to: senderWidth)
            line += "  " + Self.clip(message.subject, to: 60)
            line += "  [\(message.mailbox)]"
            lines.append(line + "  id=\(message.id.encoded)")
        }

        if page.results.count < page.total {
            lines.append(
                "…\(page.total - page.results.count) more matched · raise 'limit' to see them")
        }
        if page.hitScanLimit {
            // A ceiling that goes unmentioned reads as "this is everything".
            lines.append(
                "⚠ Scan limit reached before the mailbox was exhausted — older matches may exist."
            )
        }
        lines.append("• marks unread.")
        return lines.joined(separator: "\n")
    }

    public func detail(_ message: MessageDetail) -> String {
        var text = message.subject + "\n"
        text += Self.block([
            ("from", message.sender),
            ("to", message.recipients.joined(separator: ", ")),
            ("cc", message.ccRecipients.joined(separator: ", ")),
            ("reply-to", message.replyTo),
            ("sent", stamp(message.dateSent, withYear: true)),
            ("received", stamp(message.dateReceived, withYear: true)),
            ("mailbox", "\(message.account) / \(message.mailbox)"),
            ("read", message.isRead ? "yes" : "no"),
            ("message-id", message.rfcMessageID),
            ("id", message.id.encoded),
        ])
        text += "\n\n" + message.body
        if message.bodyTruncated {
            text += "\n\n[Body truncated. Raise 'body_limit' to read more.]"
        }
        return text
    }

    /// The receipt is the only record the caller gets of something that cannot be undone,
    /// so it repeats every address the message actually went to — including bcc.
    public func sent(_ receipt: SentReceipt) -> String {
        var text = "Sent. This cannot be recalled.\n\n"
        text += Self.block([
            ("from", receipt.sender),
            ("to", receipt.to.joined(separator: ", ")),
            ("cc", receipt.cc.isEmpty ? nil : receipt.cc.joined(separator: ", ")),
            ("bcc", receipt.bcc.isEmpty ? nil : receipt.bcc.joined(separator: ", ")),
            ("subject", receipt.subject),
        ])
        text += "\n\n" + receipt.bodyPreview
        return text
    }

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
        // The fixed defaults: naming them here is the only way to see them, now that
        // there is no settings form to read them back from.
        text += Self.block([
            ("binary", binaryPath),
            ("target", ScriptingBridgeMailStore.bundleIdentifier),
            ("process", "pid \(ProcessInfo.processInfo.processIdentifier)"),
            ("default mailbox", Configuration.defaultMailbox ?? "none (searches every mailbox)"),
            ("scan ceiling", "\(Configuration.scanCeiling) messages"),
            ("body limit", "\(Configuration.bodyLimit) characters"),
            ("default results", "\(Configuration.searchLimit)"),
        ])
        if state != .ready {
            text += "\n\n" + ToolError.availabilityMessage(state)
        }
        return text
    }
}
