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
/// header for why they cannot live in Swift. The policy of a search (which mailboxes to
/// walk, how a query matches, where to stop) is `MailScan`, which the tests run against
/// invented mailboxes. What is left here is the part no test can reach, kept thin: handing
/// the bridge to that policy and turning what comes back into the model's types.
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
        unreadOnly: Bool, scanCeiling: Int, timeLimit: Duration
    ) async throws -> MessageScan {
        let everyAccount = try await accounts()
        let seconds =
            Double(timeLimit.components.seconds) + Double(timeLimit.components.attoseconds) / 1e18
        let deadline = Date().addingTimeInterval(seconds)

        do {
            return try MailScan.run(
                accounts: everyAccount, query: query, account: account, mailbox: mailbox,
                unreadOnly: unreadOnly, scanCeiling: scanCeiling,
                isPastDeadline: { Date() >= deadline }
            ) { accountName, mailboxName, maximum in
                let walked = try MailBridge.scanMailbox(
                    mailboxName, inAccount: accountName, from: from, to: to, maxScan: maximum,
                    deadline: deadline)
                let messages = (walked["messages"] as? [[String: Any]] ?? []).compactMap {
                    raw -> MailScan.Message? in
                    guard let identifier = raw["id"] as? Int else { return nil }
                    return MailScan.Message(
                        id: identifier, subject: raw["subject"] as? String ?? "",
                        sender: raw["sender"] as? String ?? "",
                        dateReceived: raw["dateReceived"] as? Date ?? .distantPast,
                        isRead: raw["isRead"] as? Bool ?? false)
                }
                return MailScan.Mailbox(
                    messages: messages, reachedMaximum: walked["reachedMaximum"] as? Bool ?? false,
                    ranOutOfTime: walked["ranOutOfTime"] as? Bool ?? false)
            }
        } catch { throw storeFailure(error) }
    }

    // MARK: Fetch

    public func fetch(id: EmailID) async throws -> MessageDetail? {
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
            body: raw["body"] as? String ?? "")
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
            body: draft.body)
    }
}
