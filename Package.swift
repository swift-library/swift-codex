// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "swift-codex",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(
      name: "Codex",
      targets: ["Codex"],
    ),
    .library(
      name: "CodexAppServerClient",
      targets: ["CodexAppServerClient"],
    ),
    .library(
      name: "CodexAppServerProtocol",
      targets: ["CodexAppServerProtocol"],
    ),
    .library(
      name: "CodexAppServerRuntime",
      targets: ["CodexAppServerRuntime"],
    ),
    .library(
      name: "CodexAppServerStdio",
      targets: ["CodexAppServerStdio"],
    ),
    .library(
      name: "CodexAppServerURLSession",
      targets: ["CodexAppServerURLSession"],
    ),
    .library(
      name: "CodexAppServerNIO",
      targets: ["CodexAppServerNIO"],
    ),
    .library(
      name: "CodexAppServerVapor",
      targets: ["CodexAppServerVapor"],
    ),
    .library(
      name: "CodexAppServerHummingbird",
      targets: ["CodexAppServerHummingbird"],
    ),
    .library(
      name: "CodexMCP",
      targets: ["CodexMCP"],
    ),
    .library(
      name: "CodexExec",
      targets: ["CodexExec"],
    ),
  ],
  dependencies: [
    .package(
      url: "https://github.com/swiftlang/swift-docc-plugin",
      from: "1.0.0"
    ),
    .package(
      url: "https://github.com/apple/swift-system.git",
      from: "1.0.0"
    ),
    .package(
      url: "https://github.com/modelcontextprotocol/swift-sdk.git",
      .upToNextMinor(from: "0.12.0")
    ),
    .package(
      url: "https://github.com/apple/swift-nio.git",
      from: "2.99.0"
    ),
    .package(
      url: "https://github.com/apple/swift-nio-ssl.git",
      from: "2.37.0"
    ),
    .package(
      url: "https://github.com/vapor/vapor.git",
      from: "4.121.4"
    ),
    .package(
      url: "https://github.com/hummingbird-project/hummingbird.git",
      from: "2.14.0"
    ),
    .package(
      url: "https://github.com/hummingbird-project/hummingbird-websocket.git",
      from: "2.6.0"
    ),
  ],
  targets: [
    .plugin(
      name: "CodexAppServerProtocolGenerator",
      capability: .buildTool(),
      dependencies: [
        "codex-app-server-protocol-generator"
      ]
    ),
    .plugin(
      name: "CodexAppServerProtocolGeneratorCommand",
      capability: .command(
        intent: .custom(
          verb: "codex-app-server-protocol-generator",
          description: "Run the Codex AppServer protocol generator"
        ),
        permissions: [
          .writeToPackageDirectory(
            reason: "Allow explicit generation into package-owned diagnostics or checked paths"
          )
        ]
      ),
      dependencies: [
        "codex-app-server-protocol-generator"
      ]
    ),
    .target(
      name: "_CodexAppServerProtocolGeneratorCore",
      path: "Plugins/_CodexAppServerProtocolGeneratorCore"
    ),
    .executableTarget(
      name: "codex-app-server-protocol-generator",
      dependencies: ["_CodexAppServerProtocolGeneratorCore"],
      path: "Plugins/CodexAppServerProtocolGeneratorTool"
    ),
    .target(
      name: "Codex",
      dependencies: ["CodexExec"]
    ),
    .target(
      name: "CodexAppServerClient",
      dependencies: [
        "CodexAppServerProtocol",
        "CodexAppServerRuntime",
      ],
      plugins: ["CodexAppServerProtocolGenerator"]
    ),
    .target(
      name: "CodexAppServerProtocol",
      dependencies: ["CodexAppServerRuntime"],
      plugins: ["CodexAppServerProtocolGenerator"]
    ),
    .target(
      name: "CodexAppServerRuntime",
    ),
    .target(
      name: "CodexAppServerStdio",
      dependencies: ["CodexAppServerRuntime"],
    ),
    .target(
      name: "CodexAppServerURLSession",
      dependencies: ["CodexAppServerRuntime"],
    ),
    .target(
      name: "CodexAppServerNIO",
      dependencies: [
        "CodexAppServerRuntime",
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOSSL", package: "swift-nio-ssl"),
        .product(name: "NIOWebSocket", package: "swift-nio"),
      ],
    ),
    .target(
      name: "CodexAppServerVapor",
      dependencies: [
        "CodexAppServerRuntime",
        .product(name: "Vapor", package: "vapor"),
      ],
    ),
    .target(
      name: "CodexAppServerHummingbird",
      dependencies: [
        "CodexAppServerRuntime",
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
        .product(name: "NIOWebSocket", package: "swift-nio"),
      ],
    ),
    .target(
      name: "CodexAppServerTestingSupport",
      dependencies: [
        "CodexAppServerProtocol",
        "CodexAppServerRuntime",
      ],
      path: "Tests/CodexAppServerTestingSupport"
    ),
    .target(
      name: "CodexMCP",
      dependencies: [
        .product(name: "MCP", package: "swift-sdk"),
        .product(name: "SystemPackage", package: "swift-system"),
      ]
    ),
    .target(
      name: "CodexExec",
    ),
    .testTarget(
      name: "CodexTests",
      dependencies: ["Codex"],
    ),
    .testTarget(
      name: "CodexAppServerTests",
      dependencies: [
        "CodexAppServerClient",
        "CodexAppServerProtocol",
        "CodexAppServerRuntime",
        "CodexAppServerStdio",
        "CodexAppServerTestingSupport",
      ],
    ),
    .testTarget(
      name: "CodexAppServerStdioTests",
      dependencies: [
        "CodexAppServerRuntime",
        "CodexAppServerStdio",
      ],
    ),
    .testTarget(
      name: "CodexAppServerURLSessionTests",
      dependencies: [
        "CodexAppServerRuntime",
        "CodexAppServerURLSession",
      ],
    ),
    .testTarget(
      name: "CodexAppServerNIOTests",
      dependencies: [
        "CodexAppServerNIO",
        "CodexAppServerRuntime",
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOWebSocket", package: "swift-nio"),
      ],
    ),
    .testTarget(
      name: "CodexAppServerVaporTests",
      dependencies: [
        "CodexAppServerRuntime",
        "CodexAppServerVapor",
        .product(name: "Vapor", package: "vapor"),
      ],
    ),
    .testTarget(
      name: "CodexAppServerHummingbirdTests",
      dependencies: [
        "CodexAppServerRuntime",
        "CodexAppServerHummingbird",
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "HummingbirdTesting", package: "hummingbird"),
        .product(name: "HummingbirdWSTesting", package: "hummingbird-websocket"),
        .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
        .product(name: "NIOCore", package: "swift-nio"),
      ],
    ),
    .testTarget(
      name: "CodexAppServerTestingSupportTests",
      dependencies: ["CodexAppServerTestingSupport"],
    ),
    .testTarget(
      name: "CodexAppServerClientTests",
      dependencies: [
        "CodexAppServerClient",
        "CodexAppServerProtocol",
        "CodexAppServerRuntime",
        "CodexAppServerTestingSupport",
      ],
    ),
    .testTarget(
      name: "CodexAppServerProtocolTests",
      dependencies: [
        "CodexAppServerProtocol",
        "CodexAppServerRuntime",
        "CodexAppServerTestingSupport",
      ],
    ),
    .testTarget(
      name: "CodexAppServerRuntimeTests",
      dependencies: ["CodexAppServerRuntime"],
    ),
    .testTarget(
      name: "CodexAppServerProtocolGeneratorTests",
      dependencies: ["_CodexAppServerProtocolGeneratorCore"],
    ),
    .testTarget(
      name: "CodexMCPTests",
      dependencies: ["CodexMCP"],
    ),
    .testTarget(
      name: "CodexExecTests",
      dependencies: ["CodexExec"],
    ),
  ],
)
