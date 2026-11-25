import Foundation

/// Every error this server words. A message says what was wrong, the form allowed and what
/// to call instead, and repeats a caller's own text only through `ToolStandard.echo`.
public enum ToolError: Error, Equatable {
    case notAvailable(MailAvailability)
    case missingArgument(String)
    case badArgument(name: String, reason: String)
    case badDate(argument: String, value: String)
    case datesOutOfOrder(from: String, to: String)
    case badIdentifier(String)
    case notFound(id: String)
    case noRecipients
    case invalidAddress(String)
    case unknownSender(String, known: [String])
    case confirmationRequired
    case unknownTool(String)
    case timedOut(tool: String, seconds: Int)
    case storeFailure(String)

    public var message: String {
        switch self {
        case .notAvailable(let state):
            return Self.availabilityMessage(state)

        case .missingArgument(let name):
            return "Missing required argument '\(name)'."

        case .badArgument(let name, let reason):
            return "Argument '\(name)' is not valid: \(reason)"

        case .badDate(let argument, let value):
            return """
                Argument '\(argument)' is not a date this server accepts: '\(ToolStandard.echo(value))'

                Use \(Arguments.dateForms). A date that does not exist, such as 30 February, \
                is refused too.
                """

        case .datesOutOfOrder(let from, let to):
            return """
                to_date (\(ToolStandard.echo(to))) is before from_date (\(ToolStandard.echo(from))).

                Both are inclusive: pass a to_date on or after from_date, or leave one out \
                to run to the end.
                """

        case .badIdentifier(let raw):
            return """
                '\(ToolStandard.echo(raw))' is not a message id from this server.

                Message ids are opaque tokens produced by mail_search. They cannot be \
                typed by hand or carried over from another tool.
                """

        case .notFound(let id):
            return """
                No message found for id '\(ToolStandard.echo(id))'.

                Mail's message ids are only unique within a mailbox, and a message that \
                has been moved or deleted since the search will no longer resolve. Run \
                mail_search again.
                """

        case .noRecipients:
            return "send_mail needs at least one address in 'to'."

        case .invalidAddress(let address):
            return """
                '\(ToolStandard.echo(address))' does not look like an email address.

                Addresses must contain an @ with something either side. Nothing was sent.
                """

        // Mail silently falls back to the default account when `sender` names an address
        // it does not own, so an unchecked typo sends from the wrong identity and looks
        // like it worked. Listing the real addresses is the whole point of the refusal.
        case .unknownSender(let address, let known):
            return """
                '\(ToolStandard.echo(address))' is not one of this Mail installation's own \
                addresses, so nothing was sent.

                Available: \(Self.candidates(known))

                Use mail_accounts to see them with the account each belongs to.
                """

        case .confirmationRequired:
            return """
                send_mail requires confirm=true.

                Sending is irreversible: there is no recall, no undo, and no draft state \
                to fall back on. Show the recipients, subject and body to the person first, \
                then call again with confirm=true.
                """

        case .unknownTool(let name):
            return "'\(ToolStandard.echo(name))' is not a tool of this server."

        case .timedOut(let tool, let seconds):
            return Self.timeoutMessage(tool: tool, seconds: seconds)

        case .storeFailure(let detail):
            return "Mail returned an error: \(Self.clipped(detail, to: Configuration.failureDetailWidth))"
        }
    }

    /// A few of `known`, then how many more there are: an account list can be long, and an
    /// error is no place for all of it.
    static func candidates(_ known: [String]) -> String {
        guard !known.isEmpty else { return "(none found)" }
        let shown = known.prefix(Configuration.candidateCount).map(ToolStandard.echo)
        let rest = known.count - shown.count
        return shown.joined(separator: ", ") + (rest > 0 ? ", and \(rest) more" : "")
    }

    static func clipped(_ text: String, to width: Int) -> String {
        text.count > width ? String(text.prefix(width)) + "…" : text
    }

    /// A send that was abandoned may still go out, which a read never has to say.
    static func timeoutMessage(tool: String, seconds: Int) -> String {
        if tool == ToolCatalog.sendName {
            return """
                send_mail did not finish within \(seconds) seconds and this call stopped \
                waiting. IT IS NOT KNOWN WHETHER THE MESSAGE WAS SENT: Mail may still send it.

                Do not call send_mail again for this message. Tell the person, and have them \
                look in Mail, or look for it with mail_search in the Sent mailbox, before \
                anything is sent a second time.
                """
        }
        return """
            The call did not finish within \(seconds) seconds and was abandoned. Nothing \
            was changed: this tool only reads.

            Mail may be busy, syncing, or waiting on a dialog. mail_status says whether it \
            still answers. For mail_search, narrow by account, mailbox, from_date or to_date.
            """
    }

    static func availabilityMessage(_ state: MailAvailability) -> String {
        switch state {
        case .ready:
            return "Mail is running and automation is permitted."

        case .notInstalled:
            return """
                Mail.app was not found on this Mac.

                This server drives the Mail app through Apple events; without it there is
                nothing to talk to.
                """

        case .notRunning:
            return """
                Mail is not running.

                This server does not launch it: starting an app on your behalf is a side
                effect you did not ask for, and Mail can take a long time to sync on first
                launch. Open Mail and try again.
                """

        case .consentNotGranted:
            return """
                Automation permission for Mail has not been granted yet.

                macOS raises the dialog the first time this server sends an Apple event.
                Restart Claude Desktop, call a Mail tool, and approve
                "apple-mail-mcp wants to control Mail".
                """

        case .automationDenied:
            return """
                Automation permission for Mail is denied.

                Grant it in:
                  System Settings → Privacy & Security → Automation → apple-mail-mcp → enable Mail
                  (Spanish UI: Ajustes del Sistema → Privacidad y seguridad → Automatización)

                Then restart Claude Desktop. The grant is per target app: allowing Mail
                says nothing about any other app.
                """
        }
    }
}
