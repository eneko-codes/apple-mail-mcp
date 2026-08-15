import Foundation

public enum ToolError: Error, Equatable {
    case notAvailable(MailAvailability)
    case missingArgument(String)
    case badArgument(name: String, reason: String)
    case badDate(argument: String, value: String)
    case badIdentifier(String)
    case notFound(id: String)
    case noRecipients
    case invalidAddress(String)
    case unknownSender(String, known: [String])
    case confirmationRequired
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
                Argument '\(argument)' is not a date this server accepts: '\(value)'

                Use 2026-08-12, 2026-08-12T09:00, or 2026-08-12T09:00:00+02:00.
                """

        case .badIdentifier(let raw):
            return """
                '\(raw)' is not a message id from this server.

                Message ids are opaque tokens produced by mail_search. They cannot be
                typed by hand or carried over from another tool.
                """

        case .notFound(let id):
            return """
                No message found for id '\(id)'.

                Mail's message ids are only unique within a mailbox, and a message that
                has been moved or deleted since the search will no longer resolve. Run
                mail_search again.
                """

        case .noRecipients:
            return "send_mail needs at least one address in 'to'."

        case .invalidAddress(let address):
            return """
                '\(address)' does not look like an email address.

                Addresses must contain an @ with something either side. Nothing was sent.
                """

        // Mail silently falls back to the default account when `sender` names an address
        // it does not own, so an unchecked typo sends from the wrong identity and looks
        // like it worked. Listing the real addresses is the whole point of the refusal.
        case .unknownSender(let address, let known):
            return """
                '\(address)' is not one of this Mail installation's own addresses, so
                nothing was sent.

                Available: \(known.isEmpty ? "(none found)" : known.joined(separator: ", "))

                Use mail_accounts to see them with the account each belongs to.
                """

        case .confirmationRequired:
            return """
                send_mail requires confirm=true.

                Sending is irreversible: there is no recall, no undo, and no draft state
                to fall back on. Show the recipients, subject and body to the person first,
                then call again with confirm=true.
                """

        case .storeFailure(let detail):
            return "Mail returned an error: \(detail)"
        }
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
