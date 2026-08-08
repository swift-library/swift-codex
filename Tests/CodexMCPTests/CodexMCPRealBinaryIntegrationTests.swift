import Foundation
import Testing

@testable import CodexMCP

@Suite("CodexMCP Real Binary Integration")
struct CodexMCPRealBinaryIntegrationTests {
  @Test(
    "Optional real-binary smoke coverage verifies startup, ping, and tools/list against a real codex binary",
    .enabled(if: CodexMCPRealBinaryIntegrationConfig.isEnabledForCurrentEnvironment)
  )
  func realBinarySmokeCoverageVerifiesStartupPingAndListTools() async throws {
    let config = try #require(CodexMCPRealBinaryIntegrationConfig.makeIfEnabled())
    let client = CodexMCPClient(
      clientInfo: testMCPClientInfo,
      launchOptions: config.launchOptions
    )

    do {
      try await client.start()
      try await client.ping()

      let tools = try await client.listTools()
      let toolNames = tools.map(\.name)
      let startupMetadata = await client.startupMetadata

      #expect(toolNames == ["codex", "codex-reply"])
      #expect(startupMetadata?.protocolVersion == "2025-03-26")
    } catch {
      try? await client.stop()
      throw error
    }

    try await client.stop()
  }

  @Test(
    "Optional real-binary smoke coverage verifies deterministic stop semantics against a real codex binary",
    .enabled(if: CodexMCPRealBinaryIntegrationConfig.isEnabledForCurrentEnvironment)
  )
  func realBinarySmokeCoverageVerifiesDeterministicStop() async throws {
    let config = try #require(CodexMCPRealBinaryIntegrationConfig.makeIfEnabled())
    let client = CodexMCPClient(
      clientInfo: testMCPClientInfo,
      launchOptions: config.launchOptions
    )

    do {
      try await client.start()
      let runningState = await client.state
      #expect(runningState == .running)

      try await client.stop()
      let stoppedStateAfterFirstStop = await client.state
      #expect(stoppedStateAfterFirstStop == .stopped)

      try await client.stop()
      let stoppedStateAfterSecondStop = await client.state
      #expect(stoppedStateAfterSecondStop == .stopped)
    } catch {
      try? await client.stop()
      throw error
    }
  }

}
private struct CodexMCPRealBinaryIntegrationConfig {
  static let enableEnvironmentVariable = "SWIFT_CODEX_REAL_BINARY_TESTS"
  static let pathEnvironmentVariable = "SWIFT_CODEX_REAL_BINARY_PATH"

  let launchOptions: CodexMCPLaunchOptions

  static var isEnabledForCurrentEnvironment: Bool {
    makeIfEnabled() != nil
  }

  static func makeIfEnabled() -> Self? {
    let environment = ProcessInfo.processInfo.environment

    guard isEnabled(environment[enableEnvironmentVariable]) else {
      return nil
    }

    let mergedPath = environment["PATH"] ?? ""
    let preservedEnvironment = mergedPath.isEmpty ? [:] : ["PATH": mergedPath]

    if let configuredPath = environment[pathEnvironmentVariable], !configuredPath.isEmpty {
      guard FileManager.default.isExecutableFile(atPath: configuredPath) else {
        return nil
      }

      return Self(
        launchOptions: CodexMCPLaunchOptions(
          executableURL: URL(fileURLWithPath: configuredPath),
          environment: preservedEnvironment,
        )
      )
    }

    guard resolveExecutable(named: "codex", searchPath: mergedPath) != nil else {
      return nil
    }

    return Self(
      launchOptions: CodexMCPLaunchOptions(
        environment: preservedEnvironment
      )
    )
  }

  private static func isEnabled(_ value: String?) -> Bool {
    guard let value else {
      return false
    }

    switch value.lowercased() {
    case "1", "true", "yes", "on":
      return true
    default:
      return false
    }
  }

  private static func resolveExecutable(
    named executableName: String,
    searchPath: String
  ) -> String? {
    let directories = searchPath.split(separator: ":")
    for directory in directories {
      let candidatePath = URL(fileURLWithPath: String(directory))
        .appendingPathComponent(executableName)
        .path
      if FileManager.default.isExecutableFile(atPath: candidatePath) {
        return candidatePath
      }
    }

    return nil
  }
}
