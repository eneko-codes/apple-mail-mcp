// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "apple-mail-mcp",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1")
    ],
    targets: [
        // Every Apple event this project sends, in Objective-C.
        //
        // Not a style choice. Apple documents one way to create a scriptable object —
        // classForScriptingClass:, alloc/initWithProperties:, then insert it in the
        // container — and that pattern cannot be written in Swift: the class returned is
        // an SBPseudoClass, and a Swift metatype cast against it aborts the process
        // (swiftlang/swift#43407). In Objective-C the documented pattern compiles as
        // written and needs no unsafeBitCast anywhere. Only Foundation types cross back.
        .target(name: "MailBridge"),

        // All logic lives here so the tests can import it. The executable target below
        // is only a launcher: an executable target cannot be imported by a test target.
        .target(
            name: "MailMCPCore",
            dependencies: ["MailBridge", .product(name: "MCP", package: "swift-sdk")]
        ),
        .executableTarget(
            name: "apple-mail-mcp",
            dependencies: ["MailMCPCore"],
            // TCC identifies this binary by its own embedded Info.plist. Claude Desktop
            // spawns MCP servers through Contents/Helpers/disclaimer, which calls
            // responsibility_spawnattrs_setdisclaim, so the process is its own TCC
            // subject. Sending Apple events without NSAppleEventsUsageDescription is
            // denied without a prompt.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ])
            ]
        ),
        .testTarget(name: "MailMCPCoreTests", dependencies: ["MailMCPCore"]),
    ]
)
