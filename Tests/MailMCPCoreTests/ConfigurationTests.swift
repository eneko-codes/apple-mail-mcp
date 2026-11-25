import Foundation
import Testing

@testable import MailMCPCore

/// These once drove `Configuration.parse`. Per the owner's plug-and-play rule the
/// settings it used to parse from `user_config` are now fixed constants — there is
/// nothing left to parse — so what remains proves the constants hold the values the
/// server shipped with, and that the fixed "search everything" behaviour still works
/// with no setting left to drive it.
@Suite("Configuration")
struct ConfigurationTests {

    private func call(
        _ name: String, _ arguments: [String: Value] = [:], store: FakeMailStore = FakeMailStore()
    ) async -> (text: String, isError: Bool) {
        let tools = MailTools(store: store, calendar: Fixtures.calendar)
        let result = await tools.handle(.init(name: name, arguments: arguments))
        guard case .text(let text) = result.content.first else {
            return ("(no text content)", true)
        }
        return (text, result.isError)
    }

    /// The message window replaced the old body limit of 8,000 characters: its default is
    /// the tool standard's usual page.
    @Test("The fixed constants hold the values the server shipped with")
    func constantsMatchTheOldDefaults() {
        #expect(Configuration.defaultMailbox == nil)
        #expect(Configuration.scanCeiling == 500)
        #expect(Configuration.searchLimit == 20)
        #expect(Configuration.defaultMaxCharacters == ToolStandard.usualPage)
    }

    /// The old configurable default mailbox is gone; unset was already its meaning, and
    /// unset is now the only behaviour there is.
    @Test("Omitting a mailbox searches every mailbox — there is no default left to set")
    func noMailboxSearchesEverything() async {
        let result = await call("mail_search")
        #expect(result.text.contains("all mail"))
    }
}
