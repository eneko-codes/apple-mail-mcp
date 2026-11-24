import Foundation
import MailMCPCore

// Launcher only. Everything testable lives in MailMCPCore, which the test target
// imports; an executable target cannot be imported.
await MailMCPServer.run()
