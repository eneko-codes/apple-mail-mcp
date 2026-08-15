import Foundation

/// What used to be settings the person installing the extension could change, before the
/// owner's plug-and-play rule removed "Default mailbox", "Messages scanned per search",
/// "Message body characters" and "Default search results" from the connector's settings
/// entirely: only the per-tool allow/ask/prohibit switch in Claude Desktop controls this
/// server now. Each constant below keeps the value that was already the shipped default.
public enum Configuration {
    /// Applied when `mail_search` is called without a mailbox. `nil` means every mailbox
    /// of every account — already the meaning of an unset default, and now the only
    /// behaviour: an unbounded search across every mailbox of every account is slow
    /// enough to look like a hang, but there is no good guess to fix it with instead.
    public static let defaultMailbox: String? = nil

    /// How many messages one query pulls from a mailbox before giving up.
    public static let scanCeiling = 500

    /// Default body truncation for `mail_get`. The tool's own `body_limit` argument
    /// still wins.
    public static let bodyLimit = 8_000

    /// Default page size for `mail_search`.
    public static let searchLimit = 20

    /// Bounds for the `body_limit` and `limit` arguments each call may still pass —
    /// unlike the defaults above, those remain adjustable per call, not per install.
    public static let bodyLimitRange = 200...100_000
    public static let searchLimitRange = 1...100
}
