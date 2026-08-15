import AppKit
import Foundation
import MailBridge

/// `MailStore` backed by the real Mail app, driven through Apple events.
///
/// Nothing here reads a mailbox directly: every read is Mail doing the work and handing
/// back the result. That is why Mail has to be running, and why everything is bounded —
/// an unbounded walk over a large mailbox will appear to hang.
///
/// The Apple events themselves live in the `MailBridge` Objective-C target; see its
/// header for why they cannot live in Swift. What stays here is policy: which mailboxes
/// to walk, how a query matches, where to stop scanning, and how a result is shaped. That
/// split is deliberate — policy is what the tests can reach through `MailStore`, and the
/// bridge is the part no test can.
public struct ScriptingBridgeMailStore: MailStore {
    public static let bundleIdentifier = "com.apple.mail"

    public init() {}

    // MARK: Availability

    public func availability() -> MailAvailability {
        guard
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier)
                != nil
        else { return .notInstalled }

        // "Not running" is checked before consent, and the order matters. Consent is
        // reported as pending until the first Apple event, and that event would launch
        // Mail — starting an app on the owner's behalf is exactly the side effect this
        // server refuses to have. Answering `.notRunning` first keeps the refusal ahead
        // of the launch.
        guard MailBridge.isMailRunning else { return .notRunning }

        switch Self.automationPermission() {
        case OSStatus(errAEEventNotPermitted): return .automationDenied
        case OSStatus(errAEEventWouldRequireUserConsent): return .consentNotGranted
        case OSStatus(procNotFound): return .notRunning
        default: return .ready
        }
    }

    /// Asks TCC whether this process may drive Mail, **without sending a real event and
    /// without raising a dialog** (`askUserIfNeeded: false`). That is what lets
    /// `mail_status` be honest about permissions while reading no mail at all.
    static func automationPermission() -> OSStatus {
        var target = AEAddressDesc()
        let identifier = Data(bundleIdentifier.utf8)
        let created = identifier.withUnsafeBytes { bytes in
            AECreateDesc(typeApplicationBundleID, bytes.baseAddress, bytes.count, &target)
        }
        guard created == noErr else { return OSStatus(created) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)
    }

    private func guardAvailability() throws {
        let state = availability()
        guard !state.blocksCalls else { throw ToolError.notAvailable(state) }
    }

    /// The bridge reports failures as `NSError`; the tool layer speaks `ToolError`.
    private func storeFailure(_ error: Error) -> ToolError {
        .storeFailure(error.localizedDescription)
    }

    // MARK: Accounts

    public func accounts() async throws -> [AccountInfo] {
        try guardAvailability()
        let raw: [[String: Any]]
        do { raw = try MailBridge.accounts() } catch { throw storeFailure(error) }

        return raw.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            let mailboxes = (entry["mailboxes"] as? [[String: Any]] ?? []).compactMap {
                mailbox -> MailboxInfo? in
                guard let mailboxName = mailbox["name"] as? String else { return nil }
                return MailboxInfo(
                    name: mailboxName, unreadCount: mailbox["unreadCount"] as? Int ?? 0)
            }
            return AccountInfo(
                name: name, addresses: entry["addresses"] as? [String] ?? [],
                mailboxes: mailboxes)
        }
    }

    // MARK: Search

    public func search(
        query: String?, account: String?, mailbox: String?, from: Date?, to: Date?,
        unreadOnly: Bool, limit: Int, scanCeiling: Int
    ) async throws -> MessageSearchPage {
        let everyAccount = try await accounts()

        var remaining = scanCeiling
        var matches: [MessageSummary] = []
        var hitCeiling = false

        for entry in everyAccount where account == nil || entry.name == account {
            for box in entry.mailboxes {
                if let mailbox,
                    box.name.localizedCaseInsensitiveCompare(mailbox) != .orderedSame
                { continue }
                if remaining <= 0 {
                    hitCeiling = true
                    break
                }

                let page: [String: Any]
                do {
                    page = try MailBridge.scanMailbox(
                        box.name, inAccount: entry.name, from: from, to: to,
                        maxScan: remaining)
                } catch { throw storeFailure(error) }

                let scanned = page["scanned"] as? Int ?? 0
                // The ceiling is spent across mailboxes, not per mailbox: a walk that
                // stopped early in one mailbox must not get a fresh budget in the next,
                // or the advertised bound would mean nothing.
                if scanned >= remaining { hitCeiling = true }
                remaining -= scanned

                for raw in page["messages"] as? [[String: Any]] ?? [] {
                    guard let identifier = raw["id"] as? Int else { continue }
                    let isRead = raw["isRead"] as? Bool ?? false
                    if unreadOnly && isRead { continue }

                    let subject = raw["subject"] as? String ?? ""
                    let sender = raw["sender"] as? String ?? ""
                    if let needle = query, !needle.isEmpty,
                        !subject.localizedCaseInsensitiveContains(needle),
                        !sender.localizedCaseInsensitiveContains(needle)
                    { continue }

                    matches.append(
                        MessageSummary(
                            id: EmailID(
                                account: entry.name, mailbox: box.name, messageID: identifier),
                            subject: subject.isEmpty ? "(no subject)" : subject,
                            sender: sender,
                            dateReceived: raw["dateReceived"] as? Date ?? .distantPast,
                            isRead: isRead,
                            mailbox: box.name))
                }
                if hitCeiling { break }
            }
            if hitCeiling { break }
        }

        matches.sort { $0.dateReceived > $1.dateReceived }
        return MessageSearchPage(
            results: Array(matches.prefix(limit)), total: matches.count,
            hitScanLimit: hitCeiling)
    }

    // MARK: Fetch

    public func fetch(id: EmailID, bodyLimit: Int) async throws -> MessageDetail? {
        try guardAvailability()

        let raw: [String: Any]
        do {
            raw = try MailBridge.message(
                withIdentifier: id.messageID, inMailbox: id.mailbox, account: id.account)
        } catch let failure as NSError
            where failure.domain == MailBridgeErrorDomain
                && failure.code == MailBridgeError.messageNotFound.rawValue
        {
            // Not a failure: ids go stale whenever a message is moved, which is ordinary,
            // and the tool layer turns a nil into its own "run the search again" message.
            return nil
        } catch {
            throw storeFailure(error)
        }

        let full = raw["body"] as? String ?? ""
        let truncated = full.count > bodyLimit
        return MessageDetail(
            id: id,
            subject: (raw["subject"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? "(no subject)",
            sender: raw["sender"] as? String ?? "",
            recipients: raw["recipients"] as? [String] ?? [],
            ccRecipients: raw["ccRecipients"] as? [String] ?? [],
            replyTo: raw["replyTo"] as? String,
            dateSent: raw["dateSent"] as? Date ?? .distantPast,
            dateReceived: raw["dateReceived"] as? Date ?? .distantPast,
            isRead: raw["isRead"] as? Bool ?? false,
            mailbox: raw["mailbox"] as? String ?? id.mailbox,
            account: id.account,
            rfcMessageID: raw["rfcMessageID"] as? String,
            body: truncated ? String(full.prefix(bodyLimit)) : full,
            bodyTruncated: truncated)
    }

    // MARK: Send

    public func send(_ draft: OutgoingDraft) async throws -> SentReceipt {
        try guardAvailability()

        let sender: String
        do {
            sender = try MailBridge.sendMessage(
                from: draft.from, subject: draft.subject, body: draft.body,
                toRecipients: draft.to, ccRecipients: draft.cc, bccRecipients: draft.bcc)
        } catch { throw storeFailure(error) }

        return SentReceipt(
            to: draft.to, cc: draft.cc, bcc: draft.bcc, subject: draft.subject,
            sender: sender.isEmpty ? "(default account)" : sender,
            bodyPreview: String(draft.body.prefix(280)))
    }
}
