import Foundation

package enum CodexAppServerStdioBinaryResolutionSource: Equatable, Sendable {
  case explicitURL
  case pathSearch(directory: String)
}

package struct CodexAppServerStdioBinaryResolution: Equatable, Sendable {
  package var executableURL: URL
  package var source: CodexAppServerStdioBinaryResolutionSource

  package init(
    executableURL: URL,
    source: CodexAppServerStdioBinaryResolutionSource
  ) {
    self.executableURL = executableURL
    self.source = source
  }
}

public enum CodexAppServerStdioBinaryVersionRequirement: Equatable, Sendable {
  case disabled
  case outputContains(String)
}

package struct CodexAppServerStdioBinaryVersionProbe: Equatable, Sendable {
  package var arguments: [String]
  package var stdoutText: String
  package var stderrText: String
  package var exitStatus: Int32

  package var combinedOutputText: String {
    stdoutText + stderrText
  }

  package init(
    arguments: [String],
    stdoutText: String,
    stderrText: String,
    exitStatus: Int32
  ) {
    self.arguments = arguments
    self.stdoutText = stdoutText
    self.stderrText = stderrText
    self.exitStatus = exitStatus
  }
}

package struct CodexAppServerStdioBinaryCompatibilityReport: Equatable, Sendable {
  package var resolution: CodexAppServerStdioBinaryResolution
  package var versionProbe: CodexAppServerStdioBinaryVersionProbe?

  package init(
    resolution: CodexAppServerStdioBinaryResolution,
    versionProbe: CodexAppServerStdioBinaryVersionProbe? = nil
  ) {
    self.resolution = resolution
    self.versionProbe = versionProbe
  }
}

public struct CodexAppServerStdioConfiguration: Equatable, Sendable {
  public var executableURL: URL?
  public var executableName: String
  public var arguments: [String]
  public var environment: [String: String]?
  public var workingDirectoryURL: URL?
  public var versionRequirement: CodexAppServerStdioBinaryVersionRequirement
  public var versionProbeArguments: [String]
  /// Positive finite probe deadline, at most 60 seconds. Validation is synchronous.
  public var versionProbeTimeoutSeconds: TimeInterval
  /// Maximum UTF-8 bytes before the line feed, including any carriage return.
  /// Must be positive and no greater than the transport's 16 MiB ceiling.
  public var maximumMessageBytes: Int

  public init(
    executableURL: URL? = nil,
    executableName: String = "codex",
    arguments: [String] = ["app-server", "--listen", "stdio://"],
    environment: [String: String]? = nil,
    workingDirectoryURL: URL? = nil,
    versionRequirement: CodexAppServerStdioBinaryVersionRequirement = .disabled,
    versionProbeArguments: [String] = ["--version"],
    versionProbeTimeoutSeconds: TimeInterval = 5,
    maximumMessageBytes: Int = 16 * 1_024 * 1_024
  ) {
    self.executableURL = executableURL
    self.executableName = executableName
    self.arguments = arguments
    self.environment = environment
    self.workingDirectoryURL = workingDirectoryURL
    self.versionRequirement = versionRequirement
    self.versionProbeArguments = versionProbeArguments
    self.versionProbeTimeoutSeconds = versionProbeTimeoutSeconds
    self.maximumMessageBytes = maximumMessageBytes
  }
}

public enum CodexAppServerStdioError: Error, Equatable, Sendable {
  case executableNotFound(String)
  case executableNotExecutable(String)
  case invalidConfiguration(String)
  case executableVersionProbeFailed(executable: String, exitStatus: Int32, stderr: String)
  case executableVersionProbeTimedOut(executable: String, timeoutSeconds: Double)
  case executableVersionProbeOutputLimitExceeded(executable: String, limitBytes: Int)
  case executableVersionMismatch(expectedSubstring: String, actualOutput: String)
  case launchFailure(String)
  /// A nonzero or signalled natural exit after all owned pipe operations have joined.
  /// POSIX signals have no exit code; use waitForExit() for the native termination reason.
  /// The diagnostic retains only a bounded, line-safe, redacted stderr tail.
  case processTerminated(exitStatus: Int32?, diagnostic: String)
  case closed
}

extension CodexAppServerStdioError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .executableNotFound(let executable):
      "The Codex executable was not found: \(executable)"
    case .executableNotExecutable(let executable):
      "The Codex executable is not executable: \(executable)"
    case .invalidConfiguration(let reason), .launchFailure(let reason):
      reason
    case .executableVersionProbeFailed(let executable, let exitStatus, let stderr):
      Self.message(
        prefix: "Codex version detection failed for \(executable) with status \(exitStatus).",
        diagnostic: stderr
      )
    case .executableVersionProbeTimedOut(let executable, let timeoutSeconds):
      "Codex version detection for \(executable) timed out after \(timeoutSeconds) seconds."
    case .executableVersionProbeOutputLimitExceeded(let executable, let limitBytes):
      "Codex version detection for \(executable) exceeded its \(limitBytes)-byte output limit."
    case .executableVersionMismatch(let expectedSubstring, let actualOutput):
      "The Codex version output did not contain \(expectedSubstring). Actual output: \(actualOutput)"
    case .processTerminated(let exitStatus, let diagnostic):
      Self.message(
        prefix: exitStatus.map { "The Codex app-server exited with status \($0)." }
          ?? "The Codex app-server closed its standard I/O unexpectedly.",
        diagnostic: diagnostic
      )
    case .closed:
      "The Codex app-server transport is closed."
    }
  }

  private static func message(prefix: String, diagnostic: String) -> String {
    let trimmed = diagnostic.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? prefix : "\(prefix) \(trimmed)"
  }
}
