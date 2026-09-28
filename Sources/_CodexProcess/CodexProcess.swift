import Foundation

#if canImport(Darwin)
  import Darwin
#endif

package struct CodexProcessExit: Sendable {
  package let status: Int32
  package let wasSignalled: Bool
}

struct CodexProcessFailure: Error, LocalizedError, Sendable {
  let description: String
  var errorDescription: String? { description }
}

/// Owns one local Codex process and its parent pipe endpoints.
/// Callers cancel first, join their IO, and await exit before releasing ownership.
package final class CodexProcess: Sendable {
  package let standardInput: FileHandle
  package let standardOutput: FileHandle
  package let standardError: FileHandle

  #if os(Windows)
    private let lifetime: CodexWindowsProcess
  #elseif canImport(Darwin)
    private let lifetime: CodexDarwinProcess
  #else
    private let lifetime: CodexFoundationProcess
  #endif

  package init(
    executableURL: URL, arguments: [String], environment: [String: String],
    workingDirectory: URL?
  ) throws {
    let input = Pipe()
    let output = Pipe()
    let error = Pipe()
    standardInput = input.fileHandleForWriting
    standardOutput = output.fileHandleForReading
    standardError = error.fileHandleForReading
    #if canImport(Darwin)
      // A child closing stdin reports a write error without signalling the host.
      guard fcntl(standardInput.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    #endif
    // Only the child retains these ends after spawn. Failure must also release
    // them so a caller never inherits an extra pipe writer that suppresses EOF.
    defer {
      try? input.fileHandleForReading.close()
      try? output.fileHandleForWriting.close()
      try? error.fileHandleForWriting.close()
    }
    #if os(Windows)
      lifetime = try CodexWindowsProcess(
        executableURL: executableURL, arguments: arguments, environment: environment,
        workingDirectory: workingDirectory, input: input.fileHandleForReading,
        output: output.fileHandleForWriting, error: error.fileHandleForWriting)
    #elseif canImport(Darwin)
      lifetime = try CodexDarwinProcess(
        executableURL: executableURL, arguments: arguments, environment: environment,
        workingDirectory: workingDirectory, input: input.fileHandleForReading,
        output: output.fileHandleForWriting, error: error.fileHandleForWriting)
    #else
      lifetime = try CodexFoundationProcess(
        executableURL: executableURL, arguments: arguments, environment: environment,
        workingDirectory: workingDirectory, input: input.fileHandleForReading,
        output: output.fileHandleForWriting, error: error.fileHandleForWriting)
    #endif
  }

  deinit { lifetime.cancel() }

  package var processIdentifier: Int32 { lifetime.processIdentifier }

  package var cancellationWasRequested: Bool { lifetime.cancellationWasRequested }

  package func cancel() { lifetime.cancel() }

  package func waitForExit() async throws -> CodexProcessExit {
    try await lifetime.waitForExit()
  }

  package func waitForExit(until deadline: DispatchTime) throws -> CodexProcessExit? {
    try lifetime.waitForExit(until: deadline)
  }
}
