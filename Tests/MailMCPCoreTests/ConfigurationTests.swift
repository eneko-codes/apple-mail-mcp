import Foundation
import MCP
import Testing

@testable import MailMCPCore

/// These once drove `Configuration.parse`. Per the owner's plug-and-play rule the four
/// settings it used to parse from `user_config` are now fixed constants — there is
/// nothing left to parse — so what remains proves the constants hold the values the
/// manifest used to default to, and that the fixed "search everything" behaviour still
/// works with no setting left to drive it.
@Suite("Configuration")
struct ConfigurationTests {

    private func call(
        _ name: String, _ arguments: [String: Value] = [:], store: FakeMailStore = FakeMailStore()
    ) async -> (text: String, isError: Bool) {
        let tools = MailTools(store: store, calendar: Fixtures.calendar)
        let result = await tools.handle(.init(name: name, arguments: arguments))
        guard case .text(let text, _, _) = result.content.first else {
            return ("(no text content)", true)
        }
        return (text, result.isError ?? false)
    }

    @Test("The fixed constants match the values the manifest used to default to")
    func constantsMatchTheOldDefaults() {
        #expect(Configuration.defaultMailbox == nil)
        #expect(Configuration.scanCeiling == 500)
        #expect(Configuration.bodyLimit == 8_000)
        #expect(Configuration.searchLimit == 20)
    }

    /// The old configurable default mailbox is gone; unset was already its meaning, and
    /// unset is now the only behaviour there is.
    @Test("Omitting a mailbox searches every mailbox — there is no default left to set")
    func noMailboxSearchesEverything() async {
        let result = await call("mail_search")
        #expect(result.text.contains("all mail"))
    }
}
