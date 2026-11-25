import Foundation

/// Every size, range, default and time this server enforces, in one place. The schemas, the
/// tool descriptions, the instructions and `mail_status` quote these by interpolation, so
/// what the model reads cannot drift from what the code does.
///
/// None of it is a setting: the owner's plug-and-play rule removed every option from the
/// connector's settings, and only the per-tool allow/ask/prohibit switch in Claude Desktop
/// controls this server.
public enum Configuration {
    /// Applied when `mail_search` is called without a mailbox. `nil` means every mailbox
    /// of every account: there is no good guess to narrow it with instead.
    public static let defaultMailbox: String? = nil

    // MARK: mail_search

    /// How many messages one search looks at, across every mailbox it opens, before it
    /// stops. Each message costs several Apple events, so this is what bounds the walk.
    public static let scanCeiling = 500

    /// How long one search may spend walking mailboxes before it returns what it has. It
    /// sits well inside `callTimeLimit`, so a slow search ends as a partial result and not
    /// as an abandoned call.
    public static let scanTimeLimit = Duration.seconds(60)

    /// A row is about 200 characters with ordinary account and mailbox names, so the
    /// largest page stays well inside `ToolStandard.longestResult` and the default one
    /// inside `ToolStandard.usualPage`. `BoundsTests` renders both to hold them to that.
    public static let searchLimit = 20
    public static let searchLimitRange = 1...100

    /// The widths a sender and a subject are clipped to in a search row. `mail_get` returns
    /// both whole.
    public static let senderWidth = 32
    public static let subjectWidth = 60

    // MARK: mail_accounts

    /// A row is one account or one mailbox, about 80 characters at its widest.
    public static let accountLimit = 100
    public static let accountLimitRange = 1...300

    /// How many of an account's addresses one row holds. An account with more gets further
    /// rows, so no row grows with the data and every address is still listed.
    public static let addressesPerRow = 10

    // MARK: Pages and windows

    public static let offsetRange = 0...10_000_000

    /// Its own, far larger range: a message text can be longer than any listing has rows,
    /// and an offset moved down to a maximum would leave the end of it out of reach.
    public static let characterOffsetRange = 0...1_000_000_000

    /// The window `mail_get` returns of a message's text. The maximum is half the longest
    /// result, so a window of ordinary text leaves room for the lines around it;
    /// `ToolStandard.fitting` shrinks one whose characters take more UTF-16 units than that.
    public static let maxCharactersRange = 1...(ToolStandard.longestResult / 2)
    public static let defaultMaxCharacters = ToolStandard.usualPage

    // MARK: send_mail

    /// What the receipt repeats of the caller's own text: the start of the subject and of
    /// the body, and the first addresses of each list. The message itself is sent whole.
    public static let receiptSubjectWidth = 200
    public static let receiptBodyWidth = 280
    public static let receiptAddressCount = 50

    // MARK: Time and errors

    /// The longest any call may take before it is abandoned and answered with an error. A
    /// search bounded by `scanCeiling` and `scanTimeLimit` ends long before; this is for
    /// Mail not answering at all. Inside `ToolStandard.timeLimit`.
    public static let callTimeLimit = Duration.seconds(120)

    /// How many of Mail's own addresses an error lists before it gives the count of the rest.
    public static let candidateCount = 5

    /// How much of an error that Mail or the bridge worded is repeated.
    public static let failureDetailWidth = 300
}
