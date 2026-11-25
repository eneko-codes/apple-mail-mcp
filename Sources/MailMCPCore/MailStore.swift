import Foundation

/// Whether Mail can be driven at all, and if not, why.
///
/// There is no `authorizationStatus` for Apple events the way there is for Contacts or
/// EventKit, so this collapses several distinct causes — Mail missing, Mail not
/// running, consent refused — into one value the tools can act on.
public enum MailAvailability: Sendable, Equatable {
    case ready
    case notInstalled
    /// Mail is installed but not launched. This server does not launch it: starting an
    /// app on someone's behalf is a side effect they did not ask for.
    case notRunning
    case automationDenied
    /// macOS has not asked yet. The first real Apple event raises the dialog.
    case consentNotGranted

    /// Whether a tool call must be refused outright.
    ///
    /// `.consentNotGranted` deliberately does **not** block, which is why "may a call
    /// proceed" is a different question from "is Mail ready". macOS only shows the
    /// Automation dialog when a real Apple event is sent, so refusing here would mean the
    /// dialog never appears and the permission could never be granted at all — observed
    /// live. If consent is then refused, the event fails and the error path reports it.
    public var blocksCalls: Bool {
        switch self {
        case .ready, .consentNotGranted: return false
        case .notInstalled, .notRunning, .automationDenied: return true
        }
    }
}

/// The seam between the tool layer and Mail.
///
/// Nothing above this protocol sends an Apple event, which is what lets the tests drive
/// every branch against an in-memory double — with Mail closed and no mailbox touched.
public protocol MailStore: Sendable {
    func availability() -> MailAvailability

    func accounts() async throws -> [AccountInfo]

    /// Every match among the messages looked at, unordered, and how far the search got.
    ///
    /// `scanCeiling` bounds how many messages one search looks at and `timeLimit` how long
    /// it may walk. Both are passed per call rather than held by the store, so that the
    /// values the tools enforce and the ones `mail_status` reports cannot be two different
    /// numbers. `from` and `to` are both inclusive.
    func search(
        query: String?, account: String?, mailbox: String?, from: Date?, to: Date?,
        unreadOnly: Bool, scanCeiling: Int, timeLimit: Duration
    ) async throws -> MessageScan

    /// The whole message, or `nil` when the mailbox no longer holds that id.
    func fetch(id: EmailID) async throws -> MessageDetail?

    /// Irreversible. There is no recall.
    func send(_ draft: OutgoingDraft) async throws -> SentReceipt
}
