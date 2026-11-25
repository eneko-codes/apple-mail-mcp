import Foundation
import Testing

@testable import MailMCPCore

/// The edges of the tool standard for this server's own tools: each bound and one past it,
/// the text of each notice, pages and windows that chain, the longest result, and the texts
/// the model reads. Every account, mailbox, address and message in here is invented.
@Suite("Bounds")
struct BoundsTests {

    // MARK: Invented mail with as many rows as a test asks for

    private static func padded(_ index: Int) -> String {
        String(format: "%04d", index)
    }

    /// About as long as an ordinary account or mailbox name gets.
    private static let account = "Invented Account For Bounds"
    private static let mailbox = "Archive/Invented/Projects/2026/Quarter-3"

    /// Exactly as wide as a search row shows, so that nothing is clipped.
    private static func subject(_ index: Int) -> String {
        let start = "Invented subject \(padded(index)) "
        return start + String(repeating: "x", count: Configuration.subjectWidth - start.count)
    }

    private static func sender(_ index: Int) -> String {
        "sender-\(padded(index))-x@fictitious.invalid"
    }

    /// `count` messages in one mailbox, the newest first, a minute apart.
    private static func messages(
        _ count: Int, account: String = account, mailbox: String = mailbox, firstID: Int = 0
    ) -> [MessageDetail] {
        (0..<count).map {
            Fixtures.message(
                account: account, mailbox: mailbox, id: firstID + $0, subject: subject(firstID + $0),
                sender: sender(firstID + $0),
                received: Fixtures.date(2026, 8, 1, 9, 0).addingTimeInterval(Double(-60 * $0)))
        }
    }

    private static func oneMailbox(_ messages: [MessageDetail]) -> FakeMailStore {
        FakeMailStore(
            accounts: [
                AccountInfo(
                    name: account, addresses: ["tester@example.invalid"],
                    mailboxes: [MailboxInfo(name: mailbox, unreadCount: 0)])
            ], messages: messages)
    }

    /// One listing tool, and mail that gives it `count` rows of the widest ordinary width,
    /// in the order the tool lists them. `row` is text found in row `index` only.
    private struct Listing: Sendable, CustomTestStringConvertible {
        var tool: String
        var things: String
        var limits: ClosedRange<Int>
        var defaultLimit: Int
        var store: @Sendable (Int) -> FakeMailStore
        var row: @Sendable (Int) -> String

        var testDescription: String { tool }

        func call(_ count: Int, _ arguments: [String: Value] = [:]) async -> ToolResult {
            await MailMCPCoreTests.call(tool, arguments, store: store(count))
        }

        /// The rows, of `count` in all, that `text` shows, in order.
        func rows(in text: String, of count: Int) -> [Int] {
            (0..<count).filter { text.contains(row($0)) }
        }
    }

    private static let search = Listing(
        tool: ToolCatalog.searchName, things: "messages", limits: Configuration.searchLimitRange,
        defaultLimit: Configuration.searchLimit,
        store: { oneMailbox(messages($0)) },
        row: { "Invented subject \(padded($0)) " })

    /// Row 0 is the account and the others are its mailboxes, in name order.
    private static let accounts = Listing(
        tool: ToolCatalog.accountsName, things: "rows",
        limits: Configuration.accountLimitRange, defaultLimit: Configuration.accountLimit,
        store: { count in
            FakeMailStore(
                accounts: count == 0
                    ? []
                    : [
                        AccountInfo(
                            name: account, addresses: ["tester@example.invalid", "tester@fictitious.invalid"],
                            // Out of order, as Mail may hand them over.
                            mailboxes: (1..<count).reversed().map {
                                MailboxInfo(name: "Invented/Projects/2026/Row-\(padded($0))", unreadCount: 12_345)
                            })
                    ], messages: [])
        },
        row: { $0 == 0 ? "\(account)  <" : "Row-\(padded($0))  " })

    private static let listings = [search, accounts]

    // MARK: Pages

    @Test("A call with no optional argument returns one default page, announced before the data", arguments: listings)
    private func defaultPage(_ listing: Listing) async {
        let total = listing.defaultLimit + 5
        let result = await listing.call(total)
        #expect(!result.isError)
        #expect(
            result.text.hasPrefix(
                "Showing 1–\(listing.defaultLimit) of \(total) \(listing.things). Pass offset=\(listing.defaultLimit) for the next page.\n\n"))
        #expect(listing.rows(in: result.text, of: total) == Array(0..<listing.defaultLimit))
        #expect(result.text.utf16.count <= ToolStandard.usualPage)
    }

    @Test("A result that holds every row from the start carries no notice", arguments: listings)
    private func wholeListingHasNoNotice(_ listing: Listing) async {
        let result = await listing.call(listing.defaultLimit)
        #expect(listing.rows(in: result.text, of: listing.defaultLimit).count == listing.defaultLimit)
        #expect(!result.text.contains("Showing"))
        #expect(!result.text.contains("is outside"))
        #expect(!result.text.contains("clipped"))
        #expect(!result.text.contains("stopped"))
    }

    @Test("limit at its maximum is used as asked, and a full page of the widest rows fits a result", arguments: listings)
    private func limitAtItsMaximum(_ listing: Listing) async {
        let maximum = listing.limits.upperBound
        let total = maximum + 10
        let result = await listing.call(total, ["limit": .int(maximum)])
        #expect(!result.text.contains("is outside"))
        #expect(
            result.text.hasPrefix(
                "Showing 1–\(maximum) of \(total) \(listing.things). Pass offset=\(maximum) for the next page.\n\n"))
        #expect(listing.rows(in: result.text, of: total) == Array(0..<maximum))
        #expect(result.text.utf16.count <= ToolStandard.longestResult)
    }

    @Test("limit one past either end is moved to the nearest value, and the result says which", arguments: listings)
    private func limitPastItsRange(_ listing: Listing) async {
        let maximum = listing.limits.upperBound
        let total = maximum + 10

        let over = await listing.call(total, ["limit": .int(maximum + 1)])
        #expect(
            over.text.hasPrefix(
                """
                limit=\(maximum + 1) is outside 1–\(maximum); \(maximum) was used.
                Showing 1–\(maximum) of \(total) \(listing.things). Pass offset=\(maximum) for the next page.


                """))
        #expect(listing.rows(in: over.text, of: total) == Array(0..<maximum))

        let under = await listing.call(total, ["limit": .int(0)])
        #expect(under.text.hasPrefix("limit=0 is outside 1–\(maximum); 1 was used.\nShowing 1–1 of \(total) "))
        #expect(listing.rows(in: under.text, of: total) == [0])
    }

    @Test("Each page starts where the last one ended, and the last says that is all", arguments: listings)
    private func pagesChain(_ listing: Listing) async {
        let first = await listing.call(7, ["limit": .int(3)])
        #expect(first.text.hasPrefix("Showing 1–3 of 7 \(listing.things). Pass offset=3 for the next page.\n\n"))
        #expect(listing.rows(in: first.text, of: 7) == [0, 1, 2])

        let second = await listing.call(7, ["limit": .int(3), "offset": .int(3)])
        #expect(second.text.hasPrefix("Showing 4–6 of 7 \(listing.things). Pass offset=6 for the next page.\n\n"))
        #expect(listing.rows(in: second.text, of: 7) == [3, 4, 5])

        let last = await listing.call(7, ["limit": .int(3), "offset": .int(6)])
        #expect(last.text.hasPrefix("Showing 7–7 of 7 \(listing.things). That is all.\n\n"))
        #expect(listing.rows(in: last.text, of: 7) == [6])
    }

    @Test("An offset past the end returns no row and says so; a negative one is moved to zero", arguments: listings)
    private func offsetEdges(_ listing: Listing) async {
        let past = await listing.call(7, ["offset": .int(7)])
        #expect(!past.isError)
        #expect(past.text.hasPrefix("Showing 0 of 7 \(listing.things): offset=7 is past the end. That is all.\n\n"))
        #expect(listing.rows(in: past.text, of: 7).isEmpty)
        #expect(past.text.contains("(nothing at this offset)"))

        let lastRow = await listing.call(7, ["offset": .int(6)])
        #expect(listing.rows(in: lastRow.text, of: 7) == [6])

        let negative = await listing.call(7, ["offset": .int(-1)])
        let range = Configuration.offsetRange
        #expect(negative.text.hasPrefix("offset=-1 is outside \(range.lowerBound)–\(range.upperBound); 0 was used.\n\n"))
        #expect(listing.rows(in: negative.text, of: 7) == Array(0..<7))
    }

    @Test("An empty listing says nothing matched, with no page notice", arguments: listings)
    private func emptyListing(_ listing: Listing) async {
        let none = await listing.call(0)
        #expect(!none.isError)
        #expect(!none.text.contains("(nothing at this offset)"))
        #expect(!none.text.contains("Showing"))
    }

    @Test("A listing states its order")
    func orderIsStated() async {
        #expect(await Self.search.call(1).text.contains("Newest first"))
        #expect(await Self.accounts.call(2).text.contains("ordered by account name, then mailbox name"))
    }

    @Test("Messages received at the same moment are ordered by account, mailbox and id, so no two tie")
    func searchOrderHasNoTies() async {
        let moment = Fixtures.date(2026, 8, 1, 9, 0)
        let store = FakeMailStore(
            accounts: Fixtures.accounts,
            messages: [
                Fixtures.message(account: "Work", id: 7, subject: "tie-d", sender: "a@fictitious.invalid", received: moment),
                Fixtures.message(mailbox: "Sent", id: 5, subject: "tie-c", sender: "a@fictitious.invalid", received: moment),
                Fixtures.message(id: 9, subject: "tie-b", sender: "a@fictitious.invalid", received: moment),
                Fixtures.message(id: 3, subject: "tie-a", sender: "a@fictitious.invalid", received: moment),
                Fixtures.message(
                    account: "Work", id: 1, subject: "newest", sender: "a@fictitious.invalid",
                    received: moment.addingTimeInterval(1)),
            ])
        let text = await call(ToolCatalog.searchName, store: store).text
        let positions = ["newest", "tie-a", "tie-b", "tie-c", "tie-d"].compactMap { text.range(of: $0)?.lowerBound }
        #expect(positions.count == 5 && positions == positions.sorted())
    }

    @Test("Accounts and mailboxes are ordered by name whatever order Mail lists them in, and a page that starts inside an account says whose mailboxes it holds")
    func accountsOrderAndContinuation() async {
        let store = FakeMailStore(
            accounts: [
                AccountInfo(
                    name: "Zeta", addresses: ["tester@fictitious.invalid"],
                    mailboxes: [MailboxInfo(name: "Folder 10", unreadCount: 0), MailboxInfo(name: "folder 2", unreadCount: 3)]),
                AccountInfo(name: "alpha", addresses: [], mailboxes: [MailboxInfo(name: "INBOX", unreadCount: 0)]),
            ], messages: [])
        let whole = await call(ToolCatalog.accountsName, store: store).text
        let positions = ["alpha", "INBOX", "Zeta  <tester@fictitious.invalid>", "folder 2   3 unread", "Folder 10"]
            .compactMap { whole.range(of: $0)?.lowerBound }
        #expect(positions.count == 5 && positions == positions.sorted())
        #expect(whole.hasPrefix("2 accounts, 3 mailboxes, ordered by"))

        let tail = await call(ToolCatalog.accountsName, ["offset": .int(3)], store: store).text
        #expect(tail.hasPrefix("Showing 4–5 of 5 rows. That is all.\n\n"))
        #expect(tail.contains("Zeta (continued)\n    folder 2"))
    }

    @Test("An account with many addresses spreads them over rows of a fixed size, and every address is listed")
    func manyAddressesTakeSeveralRows() async {
        let size = Configuration.addressesPerRow
        let addresses = (0..<(size * 2 + 5)).map { "alias-\(Self.padded($0))@example.invalid" }
        let store = FakeMailStore(
            accounts: [
                AccountInfo(name: "Personal", addresses: addresses, mailboxes: [MailboxInfo(name: "INBOX", unreadCount: 0)])
            ], messages: [])
        let whole = await call(ToolCatalog.accountsName, store: store).text
        #expect(!whole.contains("Showing"))
        #expect(addresses.allSatisfy { whole.contains($0) })
        #expect(whole.contains("Personal  <alias-0000@example.invalid, "))
        #expect(whole.contains("alias-\(Self.padded(size - 1))@example.invalid>\n  more addresses  <alias-\(Self.padded(size))@example.invalid, "))

        let second = await call(ToolCatalog.accountsName, ["limit": .int(1), "offset": .int(2)], store: store).text
        #expect(second.hasPrefix("Showing 3–3 of 4 rows. Pass offset=3 for the next page.\n\n"))
        #expect(second.contains("Personal (continued)\n  more addresses  <alias-\(Self.padded(size * 2))@example.invalid, "))
        #expect(!second.contains("alias-0000@"))
    }

    // MARK: Rows wider than any maximum foresaw

    @Test("A page of rows too wide to fit holds fewer of them and says where to resume")
    func widePageShrinks() async throws {
        let wide = "Invented/" + String(repeating: "w", count: 600)
        let total = 150
        func store() -> FakeMailStore {
            FakeMailStore(
                accounts: [AccountInfo(name: Self.account, addresses: [], mailboxes: [MailboxInfo(name: wide, unreadCount: 0)])],
                messages: Self.messages(total, mailbox: wide))
        }
        var offset = 0
        var seen: [Int] = []
        while offset < total {
            let result = await call(
                ToolCatalog.searchName, ["limit": .int(100), "offset": .int(offset)], store: store())
            #expect(result.text.utf16.count <= ToolStandard.longestResult)
            let shown = Self.search.rows(in: result.text, of: total)
            let last = try #require(shown.last)
            #expect(shown.first == offset)
            #expect(shown.count < 100)
            let next = last + 1 < total ? "Pass offset=\(last + 1) for the next page." : "That is all."
            #expect(result.text.hasPrefix("Showing \(offset + 1)–\(last + 1) of \(total) messages. \(next)\n\n"))
            seen += shown
            offset = last + 1
        }
        #expect(seen == Array(0..<total))
    }

    @Test("A sender or subject wider than its column is clipped, the result says so before the data, and mail_get returns it whole")
    func clippedFieldsAreAnnounced() async {
        let longSubject = "Invented subject " + String(repeating: "s", count: 100) + " END-OF-SUBJECT"
        let longSender = "Invented Sender " + String(repeating: "n", count: 40) + " <tail@fictitious.invalid>"
        let message = Fixtures.message(
            account: Self.account, mailbox: Self.mailbox, id: 1, subject: longSubject, sender: longSender,
            received: Fixtures.date(2026, 8, 1))
        let store = Self.oneMailbox([message])

        let listed = await call(ToolCatalog.searchName, store: store)
        #expect(
            listed.text.hasPrefix(
                """
                Sender is clipped to \(Configuration.senderWidth) characters in each row. Read one in full with mail_get.
                Subject is clipped to \(Configuration.subjectWidth) characters in each row. Read one in full with mail_get.


                """))
        #expect(!listed.text.contains("END-OF-SUBJECT"))
        #expect(!listed.text.contains("tail@fictitious.invalid"))
        #expect(listed.text.contains(String(longSubject.prefix(Configuration.subjectWidth - 1)) + "…"))

        let read = await call(ToolCatalog.getName, ["id": .string(message.id.encoded)], store: store)
        #expect(read.text.contains(longSubject))
        #expect(read.text.contains(longSender))
    }

    // MARK: Where a search stops

    private static let twoMailboxes = [
        AccountInfo(
            name: account, addresses: [],
            mailboxes: [MailboxInfo(name: "First", unreadCount: 0), MailboxInfo(name: "Second", unreadCount: 0)])
    ]

    @Test("The scan ceiling is spent across mailboxes, and the result says how far the search got")
    func ceilingIsSharedAcrossMailboxes() async {
        let ceiling = Configuration.scanCeiling
        let store = FakeMailStore(
            accounts: Self.twoMailboxes,
            messages: Self.messages(ceiling, mailbox: "First") + Self.messages(3, mailbox: "Second", firstID: 9000))
        let result = await call(ToolCatalog.searchName, ["limit": .int(5)], store: store)
        #expect(
            result.text.hasPrefix(
                """
                The scan stopped after \(ceiling) messages; more may exist. Narrow by account, mailbox, from_date or to_date.
                Showing 1–5 of \(ceiling) messages. Pass offset=5 for the next page.


                """))
        #expect(result.text.contains("Looked at \(ceiling) messages in 1 of 2 mailboxes."))
        // The second mailbox was never opened, so nothing of it is counted or shown.
        #expect(!result.text.contains(Self.search.row(9000)))

        let narrowed = await call(ToolCatalog.searchName, ["mailbox": "second"], store: store)
        #expect(!narrowed.text.contains("stopped"))
        #expect(Self.search.rows(in: narrowed.text, of: 9003) == [9000, 9001, 9002])
        #expect(narrowed.text.contains("Looked at 3 messages in 1 of 1 mailbox."))
    }

    @Test("A search that read every mailbox to its end, even exactly at the ceiling, carries no stop notice")
    func exactlyAtTheCeilingIsNotAStop() async {
        let ceiling = Configuration.scanCeiling
        let whole = await call(ToolCatalog.searchName, store: Self.oneMailbox(Self.messages(ceiling)))
        #expect(!whole.text.contains("stopped"))
        #expect(whole.text.hasPrefix("Showing 1–\(Configuration.searchLimit) of \(ceiling) messages."))

        let onePast = await call(ToolCatalog.searchName, store: Self.oneMailbox(Self.messages(ceiling + 1)))
        #expect(onePast.text.hasPrefix("The scan stopped after \(ceiling) messages; more may exist."))
    }

    @Test("A search that runs out of time returns what it has and says it is partial, before the data")
    func timeLimitGivesAPartialResult() async {
        let store = FakeMailStore(
            accounts: Self.twoMailboxes,
            messages: Self.messages(10, mailbox: "First") + Self.messages(3, mailbox: "Second", firstID: 9000))
        store.timeRunsOutAfter = 4
        let result = await call(ToolCatalog.searchName, store: store)
        #expect(!result.isError)
        #expect(
            result.text.hasPrefix(
                "Partial: the time limit was reached after 4 messages. Narrow by account, mailbox, from_date or to_date.\n\n"))
        #expect(Self.search.rows(in: result.text, of: 10) == [0, 1, 2, 3])
        #expect(result.text.contains("Looked at 4 messages in 1 of 2 mailboxes."))
    }

    @Test("Time running out between two mailboxes stops the search before the next one is opened")
    func timeLimitBetweenMailboxes() async {
        let store = FakeMailStore(
            accounts: Self.twoMailboxes,
            messages: Self.messages(4, mailbox: "First") + Self.messages(3, mailbox: "Second", firstID: 9000))
        store.timeRunsOutAfter = 4
        let result = await call(ToolCatalog.searchName, store: store)
        #expect(result.text.hasPrefix("Partial: the time limit was reached after 4 messages."))
        #expect(result.text.contains("in 1 of 2 mailboxes"))
    }

    @Test("An account or mailbox that does not exist is said to match no mailbox, not to hold no messages")
    func unknownMailboxIsNamed() async {
        let result = await call(ToolCatalog.searchName, ["mailbox": "Inbx"])
        #expect(!result.isError)
        #expect(result.text.hasPrefix("No mailbox matches in Inbx. mail_accounts lists"))
    }

    @Test("The scan policy passes each mailbox what is left of the ceiling, and never opens one it has no budget for")
    func scanPolicyBudget() {
        var asked: [(String, Int)] = []
        let scan = MailScan.run(
            accounts: [
                AccountInfo(
                    name: "A", addresses: [],
                    mailboxes: ["one", "two", "three"].map { MailboxInfo(name: $0, unreadCount: 0) })
            ],
            query: nil, account: nil, mailbox: nil, unreadOnly: false, scanCeiling: 10,
            isPastDeadline: { false }
        ) { _, mailbox, maximum in
            asked.append((mailbox, maximum))
            let held = mailbox == "one" ? 6 : 4
            return MailScan.Mailbox(
                messages: (0..<min(held, maximum)).map {
                    MailScan.Message(
                        id: $0, subject: "s", sender: "a@fictitious.invalid", dateReceived: .distantPast, isRead: true)
                }, reachedMaximum: held > maximum)
        }
        #expect(asked.map(\.0) == ["one", "two"])
        #expect(asked.map(\.1) == [10, 4])
        #expect(scan.scanned == 10 && scan.stopped == .scanCeiling)
        #expect(scan.mailboxesOpened == 2 && scan.mailboxesSelected == 3)
    }

    // MARK: The window on a message's text

    private static let longBody = (0..<900).map { "Invented line \(padded($0)) of a long body." }.joined(separator: "\n")

    private static func long(body: String = longBody, recipients: [String] = ["tester@example.invalid"]) -> MessageDetail {
        Fixtures.message(
            account: account, mailbox: mailbox, id: 77, subject: "Invented long message",
            sender: "sender@fictitious.invalid", received: Fixtures.date(2026, 8, 1, 9, 0),
            recipients: recipients, body: body)
    }

    /// What follows the facts about the message: the window itself.
    private func window(_ text: String) throws -> String {
        let marker = try #require(text.range(of: "characters of subject, headers and body\n\n"))
        return String(text[marker.upperBound...])
    }

    private func read(_ extra: [String: Value] = [:], _ message: MessageDetail = long()) async -> ToolResult {
        await call(
            ToolCatalog.getName, ["id": .string(message.id.encoded)].merging(extra) { _, new in new },
            store: Self.oneMailbox([message]))
    }

    @Test("A long message comes as one default window, announced before the data")
    func defaultWindow() async throws {
        let whole = Format.messageText(Self.long())
        let size = Configuration.defaultMaxCharacters
        #expect(whole.count > size)
        let result = await read()
        #expect(
            result.text.hasPrefix(
                "Message text: characters 1–\(size) of \(whole.count). Pass character_offset=\(size) for the rest.\n\nMessage\n"))
        #expect(try window(result.text) == String(whole.prefix(size)))
        #expect(result.text.contains("\(whole.count) characters of subject"))
    }

    @Test("Windows chain: each starts where the last ended, and together they are the whole text")
    func windowsChain() async throws {
        let whole = Format.messageText(Self.long())
        var offset = 0
        var joined = ""
        while offset < whole.count {
            let result = await read(["character_offset": .int(offset), "max_characters": .int(7000)])
            let part = try window(result.text)
            let last = offset + part.count
            let next = last < whole.count ? "Pass character_offset=\(last) for the rest." : "That is all."
            #expect(result.text.hasPrefix("Message text: characters \(offset + 1)–\(last) of \(whole.count). \(next)\n\n"))
            #expect(part.count == min(7000, whole.count - offset))
            joined += part
            offset = last
        }
        #expect(joined == whole)
        #expect(joined.hasSuffix("Invented line 0899 of a long body."))
    }

    @Test("max_characters at its maximum is used as asked; one past either end is moved and reported")
    func windowSizeBounds() async throws {
        let message = Self.long(body: String(repeating: Self.longBody + "\n", count: 2))
        let maximum = Configuration.maxCharactersRange.upperBound
        #expect(Format.messageText(message).count > maximum)

        let atMaximum = await read(["max_characters": .int(maximum)], message)
        #expect(!atMaximum.text.contains("is outside"))
        #expect(try window(atMaximum.text).count == maximum)
        #expect(atMaximum.text.utf16.count <= ToolStandard.longestResult)

        let over = await read(["max_characters": .int(maximum + 1)], message)
        #expect(
            over.text.hasPrefix(
                "max_characters=\(maximum + 1) is outside 1–\(maximum); \(maximum) was used.\nMessage text: characters 1–\(maximum) of "))
        #expect(try window(over.text).count == maximum)

        let under = await read(["max_characters": .int(0)], message)
        #expect(under.text.hasPrefix("max_characters=0 is outside 1–\(maximum); 1 was used.\nMessage text: characters 1–1 of "))
        #expect(try window(under.text) == "I")
    }

    @Test("character_offset past the end returns no text and says so; a negative one is moved to zero")
    func windowOffsetEdges() async throws {
        let whole = Format.messageText(Self.long())
        let past = await read(["character_offset": .int(whole.count + 50)])
        #expect(
            past.text.hasPrefix(
                "Message text: characters 0 of \(whole.count): character_offset=\(whole.count + 50) is past the end. That is all.\n\n"))
        #expect(try window(past.text).isEmpty)

        let negative = await read(["character_offset": .int(-3)])
        let range = Configuration.characterOffsetRange
        #expect(
            negative.text.hasPrefix(
                "character_offset=-3 is outside \(range.lowerBound)–\(range.upperBound); 0 was used.\nMessage text: characters 1–"))
    }

    @Test("A window of characters that take several UTF-16 units each still fits a result, and still chains")
    func windowOfWideCharacters() async throws {
        // Eight UTF-16 units to the character: a full window would be four results long.
        let message = Self.long(body: String(repeating: "👩‍👩‍👧", count: 30_000))
        let whole = Format.messageText(message)
        let maximum = Configuration.maxCharactersRange.upperBound
        var offset = 0
        var joined = ""
        while offset < whole.count {
            let result = await read(["character_offset": .int(offset), "max_characters": .int(maximum)], message)
            #expect(result.text.utf16.count <= ToolStandard.longestResult)
            let part = try window(result.text)
            #expect(!part.isEmpty)
            let last = offset + part.count
            #expect(result.text.hasPrefix("Message text: characters \(offset + 1)–\(last) of \(whole.count). "))
            joined += part
            offset = last
        }
        #expect(joined == whole)
    }

    @Test("A message sent to thousands of people is bounded like any other, and every recipient can be reached")
    func manyRecipientsAreWindowed() async throws {
        let recipients = (0..<3000).map { "Invented Person \(Self.padded($0)) <person-\(Self.padded($0))@fictitious.invalid>" }
        let message = Self.long(body: "Short body.", recipients: recipients)
        let whole = Format.messageText(message)

        let first = await read([:], message)
        #expect(first.text.utf16.count <= ToolStandard.usualPage + 1000)
        #expect(first.text.hasPrefix("Message text: characters 1–\(Configuration.defaultMaxCharacters) of \(whole.count). "))

        var offset = 0
        var joined = ""
        while offset < whole.count {
            let result = await read(
                ["character_offset": .int(offset), "max_characters": .int(Configuration.maxCharactersRange.upperBound)], message)
            #expect(result.text.utf16.count <= ToolStandard.longestResult)
            joined += try window(result.text)
            offset = joined.count
        }
        #expect(joined == whole)
        #expect(joined.contains("person-2999@fictitious.invalid"))
        #expect(joined.hasSuffix("Short body."))
    }

    // MARK: Numbers moved, values refused

    @Test("A wrong type is refused with the form expected")
    func wrongTypesAreRefused() async {
        let id = Fixtures.messages[0].id.encoded
        let send: [String: Value] = ["to": ["someone@example.invalid"], "subject": "Hello", "body": "Text", "confirm": true]
        let cases: [(tool: String, arguments: [String: Value], expected: String)] = [
            (ToolCatalog.searchName, ["limit": "ten"], "Argument 'limit' is not valid: a whole number was expected"),
            (ToolCatalog.searchName, ["limit": 2.5], "Argument 'limit' is not valid: a whole number was expected"),
            (ToolCatalog.searchName, ["offset": true], "Argument 'offset' is not valid: a whole number was expected"),
            (ToolCatalog.searchName, ["query": 5], "Argument 'query' is not valid: text was expected"),
            (ToolCatalog.searchName, ["mailbox": ["INBOX"]], "Argument 'mailbox' is not valid: text was expected"),
            (ToolCatalog.searchName, ["unread_only": "yes"], "Argument 'unread_only' is not valid: true or false was expected"),
            (ToolCatalog.searchName, ["from_date": 20260812], "Argument 'from_date' is not valid: text was expected"),
            (ToolCatalog.accountsName, ["limit": [1]], "Argument 'limit' is not valid"),
            (ToolCatalog.getName, ["id": 12], "Argument 'id' is not valid: text was expected"),
            (ToolCatalog.getName, ["id": .string(id), "max_characters": "all"], "Argument 'max_characters' is not valid"),
            (ToolCatalog.getName, ["id": .string(id), "character_offset": 1.5], "Argument 'character_offset' is not valid"),
            (ToolCatalog.sendName, send.merging(["confirm": "true"]) { _, new in new }, "true or false was expected"),
            (ToolCatalog.sendName, send.merging(["to": 7]) { _, new in new }, "Argument 'to' is not valid: a list of text was expected"),
            (ToolCatalog.sendName, send.merging(["subject": 7]) { _, new in new }, "Argument 'subject' is not valid: text was expected"),
        ]
        for (tool, arguments, expected) in cases {
            let store = FakeMailStore()
            let result = await call(tool, arguments, store: store)
            #expect(result.isError, "\(tool) \(arguments)")
            #expect(result.text.contains(expected), "\(tool) \(arguments): \(result.text)")
            #expect(store.sent.isEmpty)
        }
    }

    /// Dropping the entry would send the message to fewer people than the caller named.
    @Test("One recipient that is not text refuses the send instead of being dropped")
    func mixedRecipientListIsRefused() async {
        let store = FakeMailStore()
        let result = await call(
            ToolCatalog.sendName,
            ["to": ["someone@example.invalid", 7], "subject": "Hello", "body": "Text", "confirm": true], store: store)
        #expect(result.isError && result.text.contains("a list of text was expected"))
        #expect(store.sent.isEmpty)
    }

    @Test("A whole number sent as 20.0 is taken as 20, and a null as not given")
    func lenientForms() async {
        let result = await Self.search.call(30, ["limit": 20.0, "offset": .null, "query": .null, "unread_only": .null])
        #expect(!result.isError)
        #expect(result.text.hasPrefix("Showing 1–20 of 30 messages."))
    }

    @Test("A message id that does not decode is refused, never read as another one")
    func identifiersAreRefused() async {
        for id in ["101", "INBOX-101", String(repeating: "A", count: 5000)] {
            let result = await call(ToolCatalog.getName, ["id": .string(id)])
            #expect(result.isError && result.text.contains("is not a message id from this server"), "\(id.prefix(20))")
        }
        let missing = await call(ToolCatalog.getName)
        #expect(missing.isError && missing.text == "Missing required argument 'id'.")
    }

    // MARK: Dates

    private func date(_ text: String) throws -> (date: Date, isDateOnly: Bool)? {
        try Arguments(["d": .string(text)], calendar: Fixtures.calendar).optionalDate("d")
    }

    @Test("The three forms of a date are read as written, with any offset honoured")
    func dateForms() throws {
        #expect(try date("2026-08-12")?.date == Fixtures.date(2026, 8, 12))
        #expect(try date("2026-08-12")?.isDateOnly == true)
        #expect(try date("2026-08-12T09:30")?.date == Fixtures.date(2026, 8, 12, 9, 30))
        #expect(try date("2026-08-12T09:30:15")?.date == Fixtures.date(2026, 8, 12, 9, 30).addingTimeInterval(15))
        #expect(try date("2026-08-12T09:30")?.isDateOnly == false)
        // Madrid is two hours ahead of Greenwich in August.
        #expect(try date("2026-08-12T09:30:00+02:00")?.date == Fixtures.date(2026, 8, 12, 9, 30))
        #expect(try date("2026-08-12T07:30:00Z")?.date == Fixtures.date(2026, 8, 12, 9, 30))
        #expect(try date("2026-08-12T02:30:00-05:00")?.date == Fixtures.date(2026, 8, 12, 9, 30))
    }

    @Test("A date that does not exist, or is not in one of the three forms, is refused with the forms")
    func impossibleDatesAreRefused() async {
        let refused = [
            "2026-02-30", "2026-13-01", "2026-00-10", "2026-04-31", "2025-02-29", "2026-08-12T24:00",
            "2026-08-12T09:60", "2026-02-30T09:00:00+02:00", "2026-08-12T09:00:00+25:00",
            // Skipped in Madrid when the clocks go forward.
            "2026-03-29T02:30",
            "last Tuesday", "12/08/2026", "2026-8-12", "2026-08-12 09:00", "2026-08-12T09", "20260812",
            "2026-08-12T09:00:00+0200", "-026-08-12",
        ]
        for text in refused {
            let result = await call(ToolCatalog.searchName, ["from_date": .string(text)])
            #expect(result.isError, "\(text)")
            #expect(result.text.contains("Use 2026-08-12, 2026-08-12T09:00 or 2026-08-12T09:00:00+02:00."), "\(text)")
        }
        let leapDay = await call(ToolCatalog.searchName, ["from_date": "2024-02-29"])
        #expect(!leapDay.isError)
    }

    @Test("from_date and to_date are both inclusive, and a bare day takes in all of that day")
    func dateRangeIsInclusive() async {
        // The fixtures hold messages received on 3, 7 and 8 August 2026.
        let oneDay = await call(ToolCatalog.searchName, ["from_date": "2026-08-07", "to_date": "2026-08-07"])
        #expect(oneDay.text.contains("Lunch on Friday?"))
        #expect(!oneDay.text.contains("Invoice for July") && !oneDay.text.contains("Quarterly review agenda"))

        let exact = await call(
            ToolCatalog.searchName, ["from_date": "2026-08-03T09:15", "to_date": "2026-08-07T13:00"])
        #expect(exact.text.contains("Invoice for July") && exact.text.contains("Lunch on Friday?"))
        #expect(!exact.text.contains("Quarterly review agenda"))

        let fromAlone = await call(ToolCatalog.searchName, ["from_date": "2026-08-08"])
        #expect(fromAlone.text.contains("Quarterly review agenda") && !fromAlone.text.contains("Lunch on Friday?"))
        let toAlone = await call(ToolCatalog.searchName, ["to_date": "2026-08-03"])
        #expect(toAlone.text.contains("Invoice for July") && !toAlone.text.contains("Lunch on Friday?"))
    }

    @Test("A range that ends before it starts is refused with what to pass")
    func backwardsRangeIsRefused() async {
        let result = await call(ToolCatalog.searchName, ["from_date": "2026-08-07", "to_date": "2026-08-06"])
        #expect(result.isError)
        #expect(result.text.hasPrefix("to_date (2026-08-06) is before from_date (2026-08-07)."))
        #expect(result.text.contains("pass a to_date on or after from_date"))

        let sameMoment = await call(
            ToolCatalog.searchName, ["from_date": "2026-08-07T13:00", "to_date": "2026-08-07T13:00"])
        #expect(!sameMoment.isError && sameMoment.text.contains("Lunch on Friday?"))
    }

    // MARK: Errors and time

    @Test("An error repeats at most a short piece of what the caller sent")
    func errorsClipWhatTheyEcho() async {
        let long = String(repeating: "n", count: 5000)
        let clipped = String(repeating: "n", count: ToolStandard.echoWidth) + "…"
        let send: [String: Value] = ["subject": "Hello", "body": "Text", "confirm": true]
        let cases: [(tool: String, arguments: [String: Value])] = [
            (long, [:]),
            (ToolCatalog.getName, ["id": .string(long)]),
            (ToolCatalog.getName, ["id": .string(EmailID(account: long, mailbox: "INBOX", messageID: 1).encoded)]),
            (ToolCatalog.searchName, ["from_date": .string(long)]),
            (ToolCatalog.searchName, ["from_date": "2026-08-07", "to_date": .string("2026-08-06T00:00:00" + long)]),
            (ToolCatalog.sendName, send.merging(["to": .array([.string(long)])]) { _, new in new }),
            (
                ToolCatalog.sendName,
                send.merging(["to": ["someone@example.invalid"], "from": .string(long + "@example.invalid")]) { _, new in new }
            ),
        ]
        for (tool, arguments) in cases {
            let result = await call(tool, arguments)
            #expect(result.isError, "\(tool.prefix(20))")
            #expect(result.text.count < 700, "\(tool.prefix(20)): \(result.text.count)")
            #expect(!result.text.contains(String(repeating: "n", count: ToolStandard.echoWidth + 1)), "\(tool.prefix(20))")
        }
        let unknown = await call(long)
        #expect(unknown.text == "'\(clipped)' is not a tool of this server.")
    }

    @Test("A search echoes a long filter only in part")
    func scopeIsClipped() async {
        let long = String(repeating: "q", count: 5000)
        let result = await call(ToolCatalog.searchName, ["query": .string(long), "account": .string(long)])
        #expect(!result.isError)
        #expect(result.text.count < 500)
    }

    @Test("An error lists a few of Mail's own addresses and counts the rest")
    func candidatesAreCut() async {
        let addresses = (0..<40).map { "tester-\(Self.padded($0))@example.invalid" }
        let store = FakeMailStore(
            accounts: [AccountInfo(name: "Personal", addresses: addresses, mailboxes: [])], messages: [])
        let result = await call(
            ToolCatalog.sendName,
            [
                "from": "someone.else@example.invalid", "to": ["someone@example.invalid"],
                "subject": "Hello", "body": "Text", "confirm": true,
            ], store: store)
        #expect(result.isError && store.sent.isEmpty)
        let shown = Configuration.candidateCount
        #expect(result.text.contains("tester-\(Self.padded(shown - 1))@example.invalid, and \(40 - shown) more"))
        #expect(!result.text.contains("tester-\(Self.padded(shown))@example.invalid"))
        #expect(result.text.contains("mail_accounts"))
    }

    @Test("Every error this server words is far inside the longest error")
    func errorsAreShort() {
        let long = String(repeating: "n", count: 50_000)
        let states: [MailAvailability] = [.notInstalled, .notRunning, .automationDenied, .consentNotGranted]
        let errors: [ToolError] =
            states.map { .notAvailable($0) } + [
                .missingArgument("id"), .badArgument(name: "limit", reason: "a whole number was expected"),
                .badDate(argument: "from_date", value: long), .datesOutOfOrder(from: long, to: long),
                .badIdentifier(long), .notFound(id: long), .noRecipients, .invalidAddress(long),
                .unknownSender(long, known: Array(repeating: long, count: 100)), .confirmationRequired,
                .unknownTool(long), .timedOut(tool: ToolCatalog.sendName, seconds: 120),
                .timedOut(tool: ToolCatalog.searchName, seconds: 120), .storeFailure(long),
            ]
        for error in errors {
            #expect(error.message.utf16.count <= ToolStandard.longestError / 5, "\(Diagnostics.kind(of: error))")
        }
        #expect(ToolError.storeFailure(long).message.count < Configuration.failureDetailWidth + 40)
    }

    @Test("The time a search may walk and the deadline of a call are within the standard's time limit")
    func deadlineIsWithinTheTimeLimit() {
        #expect(Configuration.callTimeLimit <= ToolStandard.timeLimit)
        #expect(Configuration.scanTimeLimit < Configuration.callTimeLimit)
    }

    @Test("A read that Mail never answers is abandoned at the deadline with an error that says how to ask for less")
    func stuckReadIsAbandoned() async {
        let store = FakeMailStore()
        store.delay = .seconds(30)
        let started = ContinuousClock.now
        let result = await call(
            ToolCatalog.getName, ["id": .string(Fixtures.messages[0].id.encoded)], store: store,
            timeout: .milliseconds(100))
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(result.isError)
        #expect(result.text.contains("was abandoned"))
        #expect(result.text.contains("mail_status"))
        #expect(result.text.contains("narrow by account, mailbox, from_date or to_date"))
    }

    /// A send that outlives the wait may still go out, and a second call would send twice.
    @Test("A send that Mail never answers says the message may still go out and must not be sent again")
    func stuckSendIsNotReportedAsUnsent() async {
        let store = FakeMailStore()
        store.delay = .seconds(30)
        let result = await call(
            ToolCatalog.sendName,
            ["to": ["someone@example.invalid"], "subject": "Hello", "body": "Text", "confirm": true],
            store: store, timeout: .milliseconds(100))
        #expect(result.isError)
        #expect(result.text.contains("IT IS NOT KNOWN WHETHER THE MESSAGE WAS SENT"))
        #expect(result.text.contains("Do not call send_mail again for this message."))
        #expect(!result.text.contains("Nothing was changed"))
    }

    // MARK: The receipt of a send

    private func send(_ extra: [String: Value]) async -> ToolResult {
        let arguments: [String: Value] = [
            "to": ["someone@example.invalid"], "subject": "Hello", "body": "Text", "confirm": true,
        ]
        return await call(ToolCatalog.sendName, arguments.merging(extra) { _, new in new })
    }

    @Test("A receipt that holds everything says only that the message was sent")
    func shortReceiptHasNoNote() async {
        let result = await send([:])
        #expect(result.text.hasPrefix("Sent. This cannot be recalled.\n\n  from"))
        #expect(result.text.contains("4 characters"))
        #expect(result.text.hasSuffix("\n\nText"))
        #expect(!result.text.contains("are shown"))
    }

    @Test("A receipt shows the start of a long body and subject and says, before the data, how long each was")
    func receiptMarksWhatItCut() async {
        let body = String(repeating: "Invented sentence. ", count: 300).trimmingCharacters(in: .whitespaces)
        let subject = String(repeating: "s", count: 900)
        let result = await send(["body": .string(body), "subject": .string(subject)])
        let width = Configuration.receiptBodyWidth
        #expect(
            result.text.hasPrefix(
                """
                Sent. This cannot be recalled.
                subject: the first \(Configuration.receiptSubjectWidth) of 900 characters are shown. All of it was sent.
                body: the first \(width) of \(body.count) characters are shown. All of it was sent.

                  from
                """))
        #expect(result.text.hasSuffix("\n\n" + String(body.prefix(width))))
        #expect(result.text.utf16.count < 2000)
    }

    @Test("A receipt lists the first addresses of a long list, counts all of them, and stays bounded")
    func receiptCutsLongLists() async {
        let many = (0..<400).map { Value.string("person-\(Self.padded($0))@fictitious.invalid") }
        let longName = String(repeating: "N", count: 300) + " <named@fictitious.invalid>"
        let result = await send(["bcc": .array(many), "cc": .array([.string(longName)])])
        let shown = Configuration.receiptAddressCount
        #expect(!result.isError)
        #expect(
            result.text.hasPrefix(
                """
                Sent. This cannot be recalled.
                bcc: the first \(shown) of 400 addresses are shown. The message went to all 400.
                Addresses longer than \(ToolStandard.echoWidth) characters are shortened here. Each was used whole.


                """))
        #expect(result.text.contains("person-\(Self.padded(shown - 1))@fictitious.invalid"))
        #expect(!result.text.contains("person-\(Self.padded(shown))@fictitious.invalid"))
        #expect(result.text.utf16.count < ToolStandard.usualPage)
    }

    // MARK: What the model reads

    @Test("The instructions and every tool description are within the longest a client keeps")
    func textsAreWithinTheLimit() {
        #expect(ToolStandard.overlongTexts(instructions: MailMCPServer.instructions, catalog: ToolCatalog.all()).isEmpty)
        #expect(!MailMCPServer.instructions.isEmpty)
    }

    private func properties(of tool: Tool) -> [String: [String: Value]] {
        guard case .object(let schema) = tool.inputSchema,
            case .object(let properties)? = schema["properties"]
        else { return [:] }
        return properties.compactMapValues(\.objectValue)
    }

    @Test("Every listing's schema states the range and default of limit and offset that the code enforces", arguments: listings)
    private func schemaStatesThePage(_ listing: Listing) throws {
        let tool = try #require(ToolCatalog.all().first { $0.name == listing.tool })
        let limit = try #require(properties(of: tool)["limit"])
        #expect(limit["minimum"]?.intValue == listing.limits.lowerBound)
        #expect(limit["maximum"]?.intValue == listing.limits.upperBound)
        #expect(limit["default"]?.intValue == listing.defaultLimit)
        let offset = try #require(properties(of: tool)["offset"])
        #expect(offset["minimum"]?.intValue == Configuration.offsetRange.lowerBound)
        #expect(offset["maximum"]?.intValue == Configuration.offsetRange.upperBound)
        #expect(offset["default"]?.intValue == 0)
        // The description states the same maximum, taken from the same constant.
        #expect(tool.description?.contains("limit (up to \(listing.limits.upperBound))") == true)
        #expect(tool.description?.contains("\(listing.defaultLimit)") == true)
    }

    @Test("The window's schema states the range and default the code enforces")
    func schemaStatesTheWindow() throws {
        let tool = try #require(ToolCatalog.all().first { $0.name == ToolCatalog.getName })
        let size = try #require(properties(of: tool)["max_characters"])
        #expect(size["minimum"]?.intValue == Configuration.maxCharactersRange.lowerBound)
        #expect(size["maximum"]?.intValue == Configuration.maxCharactersRange.upperBound)
        #expect(size["default"]?.intValue == Configuration.defaultMaxCharacters)
        #expect(Configuration.defaultMaxCharacters == ToolStandard.usualPage)
        let offset = try #require(properties(of: tool)["character_offset"])
        #expect(offset["minimum"]?.intValue == 0 && offset["default"]?.intValue == 0)
        #expect(offset["maximum"]?.intValue == Configuration.characterOffsetRange.upperBound)
        #expect(tool.description?.contains("max_characters (up to \(Configuration.maxCharactersRange.upperBound))") == true)
        #expect(tool.description?.contains("first \(Configuration.defaultMaxCharacters) characters") == true)
    }

    @Test("The descriptions, the instructions and mail_status state the sizes and times the code enforces")
    func textsStateTheConstants() async {
        let search = ToolCatalog.search.description ?? ""
        let scanSeconds = Configuration.scanTimeLimit.components.seconds
        let callSeconds = Configuration.callTimeLimit.components.seconds
        #expect(search.contains("no more than \(Configuration.scanCeiling) messages"))
        #expect(search.contains("no longer than \(scanSeconds) seconds"))
        #expect(search.contains("Sender is clipped to \(Configuration.senderWidth) characters"))
        #expect(search.contains("subject to \(Configuration.subjectWidth)"))

        let instructions = MailMCPServer.instructions
        #expect(instructions.contains("mail_search returns \(Configuration.searchLimit) messages"))
        #expect(instructions.contains("mail_accounts \(Configuration.accountLimit) rows"))
        #expect(instructions.contains("first \(Configuration.defaultMaxCharacters) characters"))
        #expect(instructions.contains("no more than \(Configuration.scanCeiling) messages"))
        #expect(instructions.contains("than \(scanSeconds) seconds"))
        #expect(instructions.contains("after \(callSeconds) seconds"))

        let send = ToolCatalog.send.description ?? ""
        #expect(send.contains("first \(Configuration.receiptBodyWidth) characters"))
        #expect(send.contains("first \(Configuration.receiptAddressCount) addresses"))
        #expect(send.contains("after \(callSeconds) seconds"))

        let status = await call(ToolCatalog.statusName).text
        #expect(status.contains("up to \(Configuration.scanCeiling) messages for up to \(scanSeconds) seconds"))
        #expect(status.contains("\(Configuration.searchLimit) messages, up to \(Configuration.searchLimitRange.upperBound)"))
        #expect(status.contains("\(Configuration.defaultMaxCharacters) characters, up to \(Configuration.maxCharactersRange.upperBound)"))
        #expect(status.contains("\(callSeconds) seconds"))
    }

    @Test("Every number in a schema has a range, and every default lies inside it")
    func everyNumberHasARange() {
        for tool in ToolCatalog.all() {
            for (name, property) in properties(of: tool) where property["type"]?.stringValue == "integer" {
                guard let minimum = property["minimum"]?.intValue, let maximum = property["maximum"]?.intValue
                else {
                    Issue.record("\(tool.name).\(name) states no range")
                    continue
                }
                if let value = property["default"]?.intValue {
                    #expect((minimum...maximum).contains(value), "\(tool.name).\(name)")
                }
            }
        }
    }

    @Test("Only the standard names page, window and date a result")
    func standardArgumentNames() {
        let standard: Set = ["limit", "offset", "character_offset", "max_characters", "from_date", "to_date"]
        // 'from' and 'to' are not here: in send_mail they are the sender and the recipients.
        let lookalikes: Set = [
            "max", "count", "max_results", "page", "page_size", "skip", "start", "max_chars", "max_length",
            "char_offset", "cursor", "body_limit", "since", "until", "before", "after", "start_date", "end_date",
        ]
        var used: Set<String> = []
        for tool in ToolCatalog.all() {
            let names = Set(properties(of: tool).keys)
            #expect(names.isDisjoint(with: lookalikes), "\(tool.name)")
            used.formUnion(names.intersection(standard))
        }
        #expect(used == standard)
        for tool in ToolCatalog.all() where tool.name != ToolCatalog.sendName {
            #expect(Set(properties(of: tool).keys).isDisjoint(with: ["from", "to"]), "\(tool.name)")
        }
    }
}
