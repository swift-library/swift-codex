import CodexAppServerTestingSupport
import Foundation
import Testing

@testable import CodexAppServerClient
@testable import CodexAppServerProtocol
@testable import CodexAppServerRuntime
@testable import CodexAppServerStdio

@Suite("CodexAppServer Real Binary Integration")
struct CodexAppServerRealBinaryIntegrationTests {
  @Test(
    "Optional real-binary smoke coverage verifies app-server handshake over stdio",
    .enabled(if: CodexAppServerRealBinaryIntegrationConfig.isEnabledForCurrentEnvironment)
  )
  func realBinarySmokeCoverageVerifiesAppServerHandshakeOverStdio() async throws {
    let config = try #require(CodexAppServerRealBinaryIntegrationConfig.makeIfEnabled())
    let connection = try await config.startConnection()
    await connection.close()
  }

  @Test(
    "Optional real-binary smoke coverage verifies one stable app-server request",
    .enabled(if: CodexAppServerRealBinaryIntegrationConfig.isEnabledForCurrentEnvironment)
  )
  func realBinarySmokeCoverageVerifiesStableRequestOverStdio() async throws {
    let config = try #require(CodexAppServerRealBinaryIntegrationConfig.makeIfEnabled())
    let connection = try await config.startConnection()

    do {
      _ = try await withRealBinaryTimeout(seconds: config.operationTimeoutSeconds) {
        try await connection.configRequirementsRead()
      }
      await connection.close()
    } catch {
      await connection.close()
      throw error
    }
  }

}
private struct CodexAppServerRealBinaryIntegrationConfig {
  static let enableEnvironmentVariable = "SWIFT_CODEX_APP_SERVER_REAL_BINARY_TESTS"
  static let pathEnvironmentVariable = "SWIFT_CODEX_APP_SERVER_REAL_BINARY_PATH"
  static let versionContainsEnvironmentVariable =
    "SWIFT_CODEX_APP_SERVER_REAL_BINARY_VERSION_CONTAINS"

  let processConfiguration: CodexAppServerStdioConfiguration
  let operationTimeoutSeconds: TimeInterval

  static var isEnabledForCurrentEnvironment: Bool {
    makeIfEnabled() != nil
  }

  static func makeIfEnabled() -> Self? {
    let environment = ProcessInfo.processInfo.environment

    guard isEnabled(environment[enableEnvironmentVariable]) else {
      return nil
    }

    let executableURL: URL?
    if let configuredPath = environment[pathEnvironmentVariable], !configuredPath.isEmpty {
      guard FileManager.default.isExecutableFile(atPath: configuredPath) else {
        return nil
      }
      executableURL = URL(fileURLWithPath: configuredPath)
    } else {
      executableURL = nil
      guard canResolveDefaultExecutable(environment: environment) else {
        return nil
      }
    }

    let versionRequirement: CodexAppServerStdioBinaryVersionRequirement
    if let expectedVersionOutput = environment[versionContainsEnvironmentVariable],
      !expectedVersionOutput.isEmpty
    {
      versionRequirement = .outputContains(expectedVersionOutput)
    } else {
      versionRequirement = .disabled
    }

    return Self(
      processConfiguration: CodexAppServerStdioConfiguration(
        executableURL: executableURL,
        versionRequirement: versionRequirement
      ),
      operationTimeoutSeconds: 10
    )
  }

  func startConnection() async throws -> CodexAppServerConnection {
    let client = CodexAppServerClient(
      sessionConfiguration: .init(
        clientInfo: .init(
          name: "swift_codex_app_server_real_binary_tests",
          title: "swift-codex AppServer Real Binary Tests",
          version: "0.1.0"
        )
      ),
      transportFactory: {
        try CodexAppServerStdioTransport(configuration: processConfiguration)
      }
    )

    return try await withRealBinaryTimeout(seconds: operationTimeoutSeconds) {
      try await client.start()
    }
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

  private static func canResolveDefaultExecutable(environment: [String: String]) -> Bool {
    do {
      _ = try CodexAppServerStdioConfiguration()
        .resolveExecutable(environment: environment)
      return true
    } catch {
      return false
    }
  }
}

private struct CodexAppServerRealBinaryTimeoutError: Error, Equatable, Sendable {
  let seconds: TimeInterval
}

private func withRealBinaryTimeout<T: Sendable>(
  seconds: TimeInterval,
  operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask {
      try await operation()
    }
    group.addTask {
      try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      throw CodexAppServerRealBinaryTimeoutError(seconds: seconds)
    }

    let result = try await group.next()!
    group.cancelAll()
    return result
  }
}
