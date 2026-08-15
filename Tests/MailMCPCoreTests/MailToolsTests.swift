import Foundation
import MCP
import Testing

@testable import MailMCPCore

/// Drives the tool layer end to end against `FakeMailStore`. No test in this file sends
/// an Apple event, so the suite runs with Mail closed and no mailbox touched — which is
/// the point.
@Suite("Tool dispatch")
struct MailToolsTests {

    private func call(
        _ name: String, _ arguments: [String: Value] = [:],
        store: FakeMailStore = FakeMailStore()
    ) async -> (text: String, isError: Bool) {
        let tools = MailTools(store: store, calendar: Fixtures.calendar)
        let result = await tools.handle(.init(name: name, arguments: arguments))
        guard case .text(let text, _, _) = result.content.first else {
            return ("(no text content)", true)
        }
        return (text, result.isError ?? false)
    }

    // MARK: Catalogue

    @Test("Every tool has a unique name, title and description")
    func catalogueIsWellFormed() {
        let names = ToolCatalog.all().map(\.name)
        #expect(names.count == Set(names).count)
        for tool in ToolCatalog.all() {
            #expect(tool.description?.isEmpty == false, "\(tool.name) has no description")
            #expect(tool.title?.isEmpty == false, "\(tool.name) has no title")
        }
    }

    /// A received message is a record. Mail's dictionary offers delete, move, bounce and
    /// redirect; none of them may ever appear in this catalogue.
    @Test("No tool can delete, move or alter a received message")
    func mailboxIsAppendOnly() {
        let forbidden = ["delete", "move", "bounce", "redirect", "flag", "mark"]
        for tool in ToolCatalog.all() {
            for verb in forbidden {
                #expect(!tool.name.contains(verb), "\(tool.name) exposes '\(verb)'")
            }
        }
        let writes = ToolCatalog.all().filter { $0.annotations.readOnlyHint != true }
        #expect(writes.map(\.name) == ["send_mail"], "send_mail must be the only write tool")
    }

    @Test("Annotations match what each tool actually does")
    func annotationsAreHonest() {
        for tool in ToolCatalog.all() {
            let isRead = tool.name != "send_mail"
            #expect(tool.annotations.readOnlyHint == isRead, "\(tool.name)")
        }
        // A union `type` such as ["string", "null"] is dropped wholesale by Claude
        // Desktop's schema sanitiser, which hands the model a bare {} and turns an array
        // argument into a string on the way out. Found in the sibling contacts server,
        // where it made every list field unusable; kept here so it cannot arrive.
        for tool in ToolCatalog.all() {
            func walk(_ value: Value, path: String) {
                guard let node = value.objectValue else { return }
                if let declared = node["type"] {
                    #expect(declared.stringValue != nil, "\(path): type must not be a union")
                }
                for (key, child) in node["properties"]?.objectValue ?? [:] {
                    walk(child, path: "\(path).\(key)")
                }
                if let items = node["items"] { walk(items, path: "\(path)[]") }
            }
            walk(tool.inputSchema, path: tool.name)
        }

        // Sending is irreversible and outward-facing, which is what a client needs to
        // surface even though nothing is being deleted.
        #expect(ToolCatalog.send.annotations.destructiveHint == true)
    }

    // MARK: Identifiers

    @Test("A message id round-trips, including awkward mailbox names")
    func identifierRoundTrips() {
        for (account, mailbox) in [
            ("Personal", "INBOX"),
            ("Work | Old", "Archive/2024"),
            ("Cuenta ñ", "Bandeja de entrada"),
        ] {
            let id = EmailID(account: account, mailbox: mailbox, messageID: 42)
            let decoded = EmailID.decode(id.encoded)
            #expect(decoded == id, "\(account)/\(mailbox)")
        }
    }

    @Test("A hand-typed id is refused rather than misread")
    func handTypedIdentifierIsRefused() async {
        let result = await call("mail_get", ["id": .string("INBOX-101")])
        #expect(result.isError)
        #expect(result.text.contains("opaque"))
    }

    // MARK: Availability

    @Test("Mail not running is reported, not treated as an empty mailbox")
    func notRunningIsExplained() async {
        let store = FakeMailStore(state: .notRunning)
        let result = await call("mail_search", store: store)
        #expect(result.isError)
        #expect(result.text.contains("not running"))
        // Launching an app on the owner's behalf is a side effect they did not ask for.
        #expect(result.text.contains("does not launch"))
    }

    @Test("Denied automation names the switch and where to find it")
    func deniedAutomationExplainsItself() async {
        let result = await call("mail_accounts", store: FakeMailStore(state: .automationDenied))
        #expect(result.isError)
        #expect(result.text.contains("Automation"))
        #expect(result.text.contains("apple-mail-mcp"))
    }

    @Test("mail_status reports while everything else is refusing")
    func statusWorksWhileDenied() async {
        let result = await call("mail_status", store: FakeMailStore(state: .automationDenied))
        #expect(!result.isError)
        #expect(result.text.contains("DENIED"))
    }

    // MARK: Search

    @Test("Search lists newest first with unread marked")
    func searchListsNewestFirst() async {
        let result = await call("mail_search")
        #expect(!result.isError)
        let lines = result.text.split(separator: "\n").filter { $0.contains("id=") }
        #expect(lines.first?.contains("Quarterly review agenda") == true)
        #expect(result.text.contains("•"))
    }

    @Test("Search echoes the filters it applied")
    func searchEchoesScope() async {
        let result = await call(
            "mail_search",
            ["query": .string("invoice"), "mailbox": .string("INBOX"), "unread_only": .bool(true)])
        #expect(result.text.contains("'invoice'"))
        #expect(result.text.contains("in INBOX"))
        #expect(result.text.contains("unread only"))
    }

    /// A ceiling that goes unmentioned reads as "this is everything". The fixture has
    /// more messages than `Configuration.scanCeiling`, so the fixed ceiling is what
    /// bites here — nothing in the test lowers it.
    @Test("Hitting the scan ceiling is announced")
    func scanCeilingIsAnnounced() async {
        let tools = MailTools(
            store: FakeMailStore(messages: Fixtures.manyMessages), calendar: Fixtures.calendar)
        let result = await tools.handle(.init(name: "mail_search", arguments: [:]))
        guard case .text(let text, _, _) = result.content.first else {
            Issue.record("no text content")
            return
        }
        #expect(text.contains("Scan limit reached"))
    }

    /// The empty case needs its own wording: "no matches" alone would imply the mailbox
    /// was exhausted, when the search actually stopped early.
    @Test("An empty result that hit the ceiling says so too")
    func emptyResultStillWarnsAboutCeiling() async {
        let tools = MailTools(
            store: FakeMailStore(messages: Fixtures.manyMessages), calendar: Fixtures.calendar)
        let result = await tools.handle(
            .init(name: "mail_search", arguments: ["query": .string("nothingmatches")]))
        guard case .text(let text, _, _) = result.content.first else {
            Issue.record("no text content")
            return
        }
        #expect(text.contains("scan limit"))
    }

    @Test("A bad date is refused with the accepted forms")
    func badDateIsRefused() async {
        let result = await call("mail_search", ["from_date": .string("last Tuesday")])
        #expect(result.isError)
        #expect(result.text.contains("2026-08-12"))
    }

    // MARK: Read

    @Test("A truncated body says it was truncated")
    func truncatedBodyIsFlagged() async {
        let id = Fixtures.messages[0].id.encoded
        let result = await call("mail_get", ["id": .string(id), "body_limit": .int(200)])
        #expect(!result.isError)
        #expect(result.text.contains("Body truncated"))
    }

    @Test("A full body carries no truncation notice")
    func shortBodyIsNotFlagged() async {
        let id = Fixtures.messages[1].id.encoded
        let result = await call("mail_get", ["id": .string(id)])
        #expect(!result.text.contains("Body truncated"))
    }

    @Test("An id that no longer resolves explains why")
    func missingMessageIsExplained() async {
        let id = EmailID(account: "Personal", mailbox: "INBOX", messageID: 9999).encoded
        let result = await call("mail_get", ["id": .string(id)])
        #expect(result.isError)
        #expect(result.text.contains("mail_search"))
    }

    // MARK: Send — the irreversible one

    @Test("Send without confirm=true delivers nothing")
    func sendRequiresConfirmation() async {
        let store = FakeMailStore()
        let result = await call(
            "send_mail",
            [
                "to": .array([.string("someone@example.invalid")]),
                "subject": .string("Hello"), "body": .string("Text"),
            ], store: store)
        #expect(result.isError)
        #expect(result.text.contains("irreversible"))
        #expect(store.sent.isEmpty, "nothing may leave the machine without confirm")
    }

    @Test("Send with no recipients delivers nothing")
    func sendNeedsRecipients() async {
        let store = FakeMailStore()
        let result = await call(
            "send_mail",
            [
                "to": .array([]), "subject": .string("Hello"), "body": .string("Text"),
                "confirm": .bool(true),
            ], store: store)
        #expect(result.isError)
        #expect(store.sent.isEmpty)
    }

    /// The mistake worth catching before an irreversible send: a name where an address
    /// was meant.
    @Test("An implausible address is refused before anything is sent")
    func badAddressStopsTheSend() async {
        for bad in ["Aurora Fakeperson", "aurora@", "@madeup.invalid", "aurora at madeup.invalid"] {
            let store = FakeMailStore()
            let result = await call(
                "send_mail",
                [
                    "to": .array([.string(bad)]), "subject": .string("Hello"),
                    "body": .string("Text"), "confirm": .bool(true),
                ], store: store)
            #expect(result.isError, "\(bad) should be refused")
            #expect(store.sent.isEmpty, "\(bad) must not be sent")
        }
    }

    /// Mail accepts an unknown `sender` and quietly substitutes the default account, so
    /// an unvalidated typo would send under the wrong identity and report success.
    @Test("A from address Mail does not own is refused before anything is sent")
    func unknownSenderStopsTheSend() async {
        let store = FakeMailStore()
        let result = await call(
            "send_mail",
            [
                "from": .string("someone.else@example.invalid"),
                "to": .array([.string("someone@example.invalid")]),
                "subject": .string("Hello"), "body": .string("Text"), "confirm": .bool(true),
            ], store: store)
        #expect(result.isError)
        #expect(result.text.contains("tester@example.invalid"), "it must list the real addresses")
        #expect(store.sent.isEmpty)
    }

    @Test("A known from address is passed through in the spelling Mail knows")
    func knownSenderIsCarried() async {
        let store = FakeMailStore()
        let result = await call(
            "send_mail",
            [
                "from": .string("TESTER@Example.Invalid"),
                "to": .array([.string("someone@example.invalid")]),
                "subject": .string("Hello"), "body": .string("Text"), "confirm": .bool(true),
            ], store: store)
        #expect(!result.isError)
        #expect(store.sent.first?.from == "tester@example.invalid")
    }

    @Test("Omitting from leaves the choice to Mail")
    func absentSenderStaysAbsent() async {
        let store = FakeMailStore()
        _ = await call(
            "send_mail",
            [
                "to": .array([.string("someone@example.invalid")]),
                "subject": .string("Hello"), "body": .string("Text"), "confirm": .bool(true),
            ], store: store)
        #expect(store.sent.first?.from == nil)
    }

    @Test("Plausible address forms are accepted")
    func goodAddressesPass() {
        for good in [
            "a@b.co", "aurora@madeup.invalid", "Aurora Fakeperson <aurora@madeup.invalid>",
        ] {
            #expect(Arguments.isPlausibleAddress(good), "\(good) should be accepted")
        }
    }

    /// A bad address must be reported even when confirm was forgotten, so the caller
    /// does not fix one problem and then discover the other.
    @Test("Validation runs before the confirm check")
    func validationPrecedesConfirmation() async {
        let result = await call(
            "send_mail",
            [
                "to": .array([.string("not an address")]), "subject": .string("Hello"),
                "body": .string("Text"),
            ])
        #expect(result.text.contains("does not look like an email address"))
    }

    @Test("A confirmed send reports every address it went to, including bcc")
    func sendReceiptIsComplete() async {
        let store = FakeMailStore()
        let result = await call(
            "send_mail",
            [
                "to": .array([.string("aurora@madeup.invalid")]),
                "cc": .array([.string("basil@fictitious.invalid")]),
                "bcc": .array([.string("cecily@madeup.invalid")]),
                "subject": .string("Subject line"), "body": .string("Body text"),
                "confirm": .bool(true),
            ], store: store)
        #expect(!result.isError)
        #expect(store.sent.count == 1)
        #expect(result.text.contains("cannot be recalled"))
        #expect(result.text.contains("aurora@madeup.invalid"))
        #expect(result.text.contains("basil@fictitious.invalid"))
        #expect(result.text.contains("cecily@madeup.invalid"), "bcc must appear in the receipt")
    }

    @Test("Sending is refused outright when Mail is unavailable")
    func sendRefusedWhenUnavailable() async {
        let store = FakeMailStore(state: .automationDenied)
        let result = await call(
            "send_mail",
            [
                "to": .array([.string("aurora@madeup.invalid")]), "subject": .string("S"),
                "body": .string("B"), "confirm": .bool(true),
            ], store: store)
        #expect(result.isError)
        #expect(store.sent.isEmpty)
    }

    @Test("An unknown tool name is refused")
    func unknownToolIsRefused() async {
        let result = await call("delete_mailbox")
        #expect(result.isError)
    }

    /// Observed live: refusing while consent is merely pending meant the Automation
    /// dialog never appeared, because macOS only shows it when a real Apple event is
    /// sent — so the permission could never be granted at all.
    @Test("A pending consent lets the call through so the dialog can appear")
    func pendingConsentDoesNotBlock() {
        #expect(MailAvailability.consentNotGranted.blocksCalls == false)
        #expect(MailAvailability.ready.blocksCalls == false)
    }

    /// Everything that cannot be fixed by showing a dialog must still be refused,
    /// notably "not running": sending an event would launch Mail on the owner's behalf.
    @Test("States a dialog cannot resolve still block")
    func unresolvableStatesBlock() {
        for state in [
            MailAvailability.notInstalled, .notRunning, .automationDenied,
        ] {
            #expect(state.blocksCalls, "\(state) must block")
        }
    }
}
