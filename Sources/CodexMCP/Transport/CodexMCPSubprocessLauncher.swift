import Foundation
import _CodexProcess

internal struct CodexMCPSubprocessLaunchConfiguration: Equatable, Sendable {
  let executableURL: URL
  let arguments: [String]
  let currentDirectoryURL: URL?
  let environment: [String: String]
}

internal struct CodexMCPSubprocessLauncher: Sendable {
  var launch:
    @Sendable (CodexMCPSubprocessLaunchConfiguration) async throws -> CodexMCPManagedSubprocess

  static func environment(overrides: [String: String]) throws -> [String: String] {
    var result = ProcessInfo.processInfo.environment
    for (key, value) in overrides {
      // Reject duplicate native names among overrides before selecting a winner.
      _ = try CodexProcessEnvironment.value(for: key, in: overrides)
      result = try CodexProcessEnvironment.setting(value, for: key, in: result)
    }
    return result
  }

  static let live = Self { configuration in
    try Task.checkCancellation()
    let process = try CodexProcess(
      executableURL: configuration.executableURL, arguments: configuration.arguments,
      environment: environment(overrides: configuration.environment),
      workingDirectory: configuration.currentDirectoryURL)
    let subprocess = CodexMCPManagedSubprocess(process: process)
    await subprocess.startDrainingStderr()
    return subprocess
  }
}
