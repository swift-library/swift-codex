#if canImport(Darwin)
  import CodexAppServerClient
  import CodexAppServerNIO
  import Darwin
  import Foundation
  import Testing

  @Suite("CodexAppServerNIO Real Binary", .timeLimit(.minutes(1)))
  struct CodexAppServerNIORealBinaryTests {
    @Test(
      "Optional real-binary smoke verifies typed handshake over a Unix WebSocket",
      .enabled(if: CodexAppServerNIORealBinaryConfiguration.isEnabled)
    )
    func realBinaryHandshakeOverUnixWebSocket() async throws {
      let configuration = try #require(CodexAppServerNIORealBinaryConfiguration.makeIfEnabled())
      let socketRoot = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("swift-codex-uds-\(UUID().uuidString.prefix(8))", isDirectory: true)
      let socketURL = socketRoot.appendingPathComponent("app-server.sock")
      try FileManager.default.createDirectory(
        at: socketRoot,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      defer { try? FileManager.default.removeItem(at: socketRoot) }

      let codexHome = socketRoot.appendingPathComponent("codex-home", isDirectory: true)
      try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: false)
      let process = Process()
      process.environment = [
        "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        "CODEX_HOME": codexHome.path,
      ]
      process.currentDirectoryURL = socketRoot
      process.executableURL = configuration.executableURL
      process.arguments = ["app-server", "--listen", "unix://\(socketURL.path)"]
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()

      do {
        try await waitForSocket(socketURL, process: process)
        let client = CodexAppServerClient(
          sessionConfiguration: .init(
            clientInfo: .init(
              name: "swift_codex_nio_unix_tests",
              title: "swift-codex NIO Unix Tests",
              version: "0.1.0"
            )
          ),
          transportFactory: {
            try await CodexAppServerNIOTransport.connect(unixSocketPath: socketURL.path)
          }
        )
        let connection = try await withUnixTestTimeout(seconds: 10) {
          try await client.start()
        }
        do {
          _ = try await withUnixTestTimeout(seconds: 10) {
            try await connection.configRequirementsRead()
          }
        } catch {
          await connection.close()
          throw error
        }
        await connection.close()
        try await terminate(process)
      } catch {
        try? await terminate(process)
        throw error
      }
    }

    private func waitForSocket(_ socketURL: URL, process: Process) async throws {
      for _ in 0..<250 {
        guard process.isRunning else {
          throw CodexAppServerNIORealBinaryError.processExited(process.terminationStatus)
        }
        if FileManager.default.fileExists(atPath: socketURL.path) {
          return
        }
        try await Task.sleep(for: .milliseconds(20))
      }
      throw CodexAppServerNIORealBinaryError.socketTimedOut
    }

    private func terminate(_ process: Process) async throws {
      guard process.isRunning else { return }
      process.terminate()
      for _ in 0..<100 {
        if !process.isRunning {
          return
        }
        try await Task.sleep(for: .milliseconds(20))
      }
      _ = Darwin.kill(process.processIdentifier, SIGKILL)
      process.waitUntilExit()
      guard !process.isRunning else {
        throw CodexAppServerNIORealBinaryError.processDidNotExit
      }
    }
  }

  private struct CodexAppServerNIORealBinaryConfiguration {
    static let enabledKey = "SWIFT_CODEX_APP_SERVER_UNIX_REAL_BINARY_TESTS"
    static let pathKey = "SWIFT_CODEX_APP_SERVER_UNIX_REAL_BINARY_PATH"

    var executableURL: URL

    static var isEnabled: Bool {
      makeIfEnabled() != nil
    }

    static func makeIfEnabled() -> Self? {
      let environment = ProcessInfo.processInfo.environment
      guard Self.enabled(environment[enabledKey]) else { return nil }
      guard let path = environment[pathKey], FileManager.default.isExecutableFile(atPath: path)
      else {
        return nil
      }
      return Self(executableURL: URL(fileURLWithPath: path))
    }

    private static func enabled(_ value: String?) -> Bool {
      switch value?.lowercased() {
      case "1", "true", "yes", "on":
        true
      default:
        false
      }
    }
  }

  private enum CodexAppServerNIORealBinaryError: Error, Equatable, Sendable {
    case processExited(Int32)
    case socketTimedOut
    case processDidNotExit
    case operationTimedOut(TimeInterval)
  }

  private func withUnixTestTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask {
        try await operation()
      }
      group.addTask {
        try await Task.sleep(for: .seconds(seconds))
        throw CodexAppServerNIORealBinaryError.operationTimedOut(seconds)
      }

      let result = try await group.next()!
      group.cancelAll()
      return result
    }
  }

#endif
