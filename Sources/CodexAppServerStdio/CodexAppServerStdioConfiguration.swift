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
  public var versionProbeTimeoutSeconds: TimeInterval

  public init(
    executableURL: URL? = nil,
    executableName: String = "codex",
    arguments: [String] = ["app-server", "--listen", "stdio://"],
    environment: [String: String]? = nil,
    workingDirectoryURL: URL? = nil,
    versionRequirement: CodexAppServerStdioBinaryVersionRequirement = .disabled,
    versionProbeArguments: [String] = ["--version"],
    versionProbeTimeoutSeconds: TimeInterval = 5
  ) {
    self.executableURL = executableURL
    self.executableName = executableName
    self.arguments = arguments
    self.environment = environment
    self.workingDirectoryURL = workingDirectoryURL
    self.versionRequirement = versionRequirement
    self.versionProbeArguments = versionProbeArguments
    self.versionProbeTimeoutSeconds = versionProbeTimeoutSeconds
  }
}

public enum CodexAppServerStdioError: Error, Equatable, Sendable {
  case executableNotFound(String)
  case executableNotExecutable(String)
  case invalidConfiguration(String)
  case executableVersionProbeFailed(executable: String, exitStatus: Int32, stderr: String)
  case executableVersionProbeTimedOut(executable: String, timeoutSeconds: Double)
  case executableVersionMismatch(expectedSubstring: String, actualOutput: String)
  case launchFailure(String)
  case closed
}
