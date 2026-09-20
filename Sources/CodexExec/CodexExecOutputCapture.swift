import Foundation

/// In-memory capture budgets for one exec process. Pipes continue to drain after a limit is reached.
public struct CodexExecOutputLimits: Equatable, Sendable {
  /// Maximum raw stdout bytes retained as complete lines, including line delimiters.
  public var stdoutBytes: Int
  /// Maximum stderr bytes retained.
  public var stderrBytes: Int
  /// Maximum complete stdout lines retained and offered to the stream consumer.
  public var stdoutLines: Int

  /// Creates finite output budgets. Zero disables capture for the corresponding stream.
  public init(
    stdoutBytes: Int = 8 * 1_024 * 1_024, stderrBytes: Int = 1_024 * 1_024,
    stdoutLines: Int = 65_536
  ) {
    self.stdoutBytes = stdoutBytes
    self.stderrBytes = stderrBytes
    self.stdoutLines = stdoutLines
  }
}

/// Missing-output metadata measured at the process pipes, before text or JSON decoding.
public struct CodexExecOutputCapture: Equatable, Sendable {
  /// Raw stdout bytes omitted from both the line stream and retained observation.
  public var stdoutDroppedBytes: Int64
  /// Raw stderr bytes omitted from the retained observation.
  public var stderrDroppedBytes: Int64
  /// Whether every output byte was captured within the configured budgets.
  public var isComplete: Bool { stdoutDroppedBytes == 0 && stderrDroppedBytes == 0 }

  /// Creates capture metadata.
  public init(stdoutDroppedBytes: Int64 = 0, stderrDroppedBytes: Int64 = 0) {
    self.stdoutDroppedBytes = stdoutDroppedBytes
    self.stderrDroppedBytes = stderrDroppedBytes
  }
}

struct CodexExecCapturedStderr: Sendable {
  var data: Data
  var droppedBytes: Int64
}

/// Keeps only a complete-line prefix; an oversized line is never emitted as malformed JSON.
struct CodexExecBoundedLineParser {
  let limits: CodexExecOutputLimits
  private var pending = Data()
  private var retainedBytes = 0
  private var retainedLines = 0
  private(set) var droppedBytes: Int64 = 0
  private var exceededLimit = false

  init(limits: CodexExecOutputLimits) {
    self.limits = limits
  }

  mutating func append(_ byte: UInt8) -> String? {
    guard !exceededLimit else {
      droppedBytes += 1
      return nil
    }
    guard retainedLines < limits.stdoutLines,
      pending.count < limits.stdoutBytes - retainedBytes
    else {
      exceededLimit = true
      droppedBytes += Int64(pending.count) + 1
      pending.removeAll(keepingCapacity: false)
      return nil
    }
    pending.append(byte)
    return byte == 10 ? takeLine() : nil
  }

  mutating func finish() -> String? {
    pending.isEmpty ? nil : takeLine()
  }

  private mutating func takeLine() -> String {
    retainedBytes += pending.count
    retainedLines += 1
    while pending.last == 10 || pending.last == 13 { pending.removeLast() }
    let line = String(decoding: pending, as: UTF8.self)
    pending.removeAll(keepingCapacity: false)
    return line
  }
}
