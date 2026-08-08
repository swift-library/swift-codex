import Foundation

internal struct CodexMCPSubprocessLaunchConfiguration: Equatable, Sendable {
  let executableURL: URL
  let arguments: [String]
  let currentDirectoryURL: URL?
  let environment: [String: String]
}

internal struct CodexMCPSubprocessLauncher: Sendable {
  var launch:
    @Sendable (CodexMCPSubprocessLaunchConfiguration) async throws -> CodexMCPManagedSubprocess

  static let live = Self { configuration in
    let standardInput = Pipe()
    let standardOutput = Pipe()
    let standardError = Pipe()

    let process = Process()
    process.executableURL = configuration.executableURL
    process.arguments = configuration.arguments
    process.standardInput = standardInput
    process.standardOutput = standardOutput
    process.standardError = standardError

    if let currentDirectoryURL = configuration.currentDirectoryURL {
      process.currentDirectoryURL = currentDirectoryURL
    }

    let mergedEnvironment = ProcessInfo.processInfo.environment.merging(
      configuration.environment,
      uniquingKeysWith: { _, new in new },
    )
    process.environment = mergedEnvironment

    try process.run()

    let controller = CodexMCPLiveProcessController(
      process: process,
      standardInput: standardInput,
      standardOutput: standardOutput,
      standardError: standardError,
    )

    let subprocess = CodexMCPManagedSubprocess(
      standardInput: standardInput,
      standardOutput: standardOutput,
      standardError: standardError,
      terminateHandler: {
        try await controller.terminate()
      },
    )
    await subprocess.startDrainingStderr()
    return subprocess
  }
}

private final class CodexMCPLiveProcessController: @unchecked Sendable {
  private let process: Process
  private let standardInput: Pipe
  private let standardOutput: Pipe
  private let standardError: Pipe

  init(
    process: Process,
    standardInput: Pipe,
    standardOutput: Pipe,
    standardError: Pipe,
  ) {
    self.process = process
    self.standardInput = standardInput
    self.standardOutput = standardOutput
    self.standardError = standardError
  }

  func terminate() async throws {
    guard process.isRunning else {
      return
    }

    process.terminate()
    process.waitUntilExit()
  }
}
