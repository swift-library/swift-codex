// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "CodexWindowsIntegration",
  platforms: [.macOS(.v14)],
  dependencies: [.package(name: "swift-codex", path: "../..")],
  targets: [
    .executableTarget(name: "CodexProcessFixture", path: "Fixture"),
    .executableTarget(
      name: "CodexEnvironmentFixture", path: "EnvironmentFixture",
      linkerSettings: [.linkedLibrary("kernel32", .when(platforms: [.windows]))]),
    .testTarget(
      name: "CodexWindowsIntegrationTests",
      dependencies: [
        .product(name: "CodexExec", package: "swift-codex"),
        .product(name: "CodexAppServerStdio", package: "swift-codex"),
      ], path: "Tests"),
  ])
