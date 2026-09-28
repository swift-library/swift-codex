// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "CodexWindowsIntegration",
  platforms: [.macOS(.v14)],
  dependencies: [.package(name: "swift-codex", path: "../..")],
  targets: [
    .executableTarget(name: "CodexProcessFixture", path: "Fixture"),
    .testTarget(
      name: "CodexWindowsIntegrationTests",
      dependencies: [
        .product(name: "CodexExec", package: "swift-codex"),
        .product(name: "CodexAppServerStdio", package: "swift-codex"),
        .product(name: "CodexAppServerRuntime", package: "swift-codex"),
      ], path: "Tests"),
  ])
