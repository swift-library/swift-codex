import Foundation

/// Observable output preserved when an exec request fails after launch.
public struct CodexExecPartialObservation: Equatable, Sendable {
  /// Text captured from upstream stderr.
  public var stderrText: String
  /// Last observed assistant message or human-readable stdout body.
  public var finalMessageText: String?
  /// Decoded JSONL events observed before the failure.
  public var events: [CodexExecEvent]
  /// Session identifier observed from `thread.started`, if any.
  public var resolvedSessionID: String?

  /// Creates preserved partial output for an exec failure.
  public init(
    stderrText: String = "",
    finalMessageText: String? = nil,
    events: [CodexExecEvent] = [],
    resolvedSessionID: String? = nil
  ) {
    self.stderrText = stderrText
    self.finalMessageText = finalMessageText
    self.events = events
    self.resolvedSessionID = resolvedSessionID
  }
}

/// Errors surfaced at the `CodexExec` process and protocol boundary.
public enum CodexExecError: Error, Equatable, Sendable {
  /// The upstream executable could not be launched or monitored.
  case launchFailure(description: String)
  /// The request cannot be represented as a valid upstream invocation.
  case invalidInvocation(description: String)
  /// A resume request explicitly failed to find its target session.
  case resumeTargetNotFound(
    selector: CodexExecResumeSelector,
    partialObservation: CodexExecPartialObservation?
  )
  /// Upstream exited non-zero while preserving any observable output.
  case nonZeroExit(code: Int32, stderr: String, partialObservation: CodexExecPartialObservation?)
  /// JSONL mode produced a malformed line.
  case malformedJSONL(line: String, partialObservation: CodexExecPartialObservation?)
  /// The upstream process was interrupted by signal or interruption text.
  case interrupted(partialObservation: CodexExecPartialObservation?)
  /// The Swift task or stream consumer cancelled the request.
  case cancelled(partialObservation: CodexExecPartialObservation?)
  /// A schema or output-file contract failed at the process boundary.
  case outputFileFailure(
    path: URL, description: String, partialObservation: CodexExecPartialObservation?)
}
