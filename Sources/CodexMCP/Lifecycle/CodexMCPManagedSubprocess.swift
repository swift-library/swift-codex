import Foundation

/// Internal process owner for the `CodexMCP` child process.
internal final class CodexMCPManagedSubprocess: @unchecked Sendable {
  let standardInput: Pipe?
  let standardOutput: Pipe?
  let standardError: Pipe?

  private let terminateHandler: @Sendable () async throws -> Void
  private let stderrCapture = CodexMCPStderrCapture()

  init(
    standardInput: Pipe? = nil,
    standardOutput: Pipe? = nil,
    standardError: Pipe? = nil,
    terminateHandler: @escaping @Sendable () async throws -> Void,
  ) {
    self.standardInput = standardInput
    self.standardOutput = standardOutput
    self.standardError = standardError
    self.terminateHandler = terminateHandler
  }

  func terminate() async throws {
    try await terminateHandler()
  }

  func startDrainingStderr() async {
    guard let standardError else {
      return
    }
    await stderrCapture.start(fileHandle: standardError.fileHandleForReading)
  }

  func stderrContext() async -> String? {
    await stderrCapture.snapshot()
  }

  func closeIO() {
    Task {
      await stderrCapture.stop()
    }
    standardInput?.fileHandleForReading.closeFile()
    standardInput?.fileHandleForWriting.closeFile()
    standardOutput?.fileHandleForReading.closeFile()
    standardOutput?.fileHandleForWriting.closeFile()
    standardError?.fileHandleForReading.closeFile()
    standardError?.fileHandleForWriting.closeFile()
  }
}

private actor CodexMCPStderrCapture {
  private static let capacity = 16 * 1_024

  private var buffer = Data()
  private var task: Task<Void, Never>?

  func start(fileHandle: FileHandle) {
    guard task == nil else {
      return
    }

    task = Task.detached {
      while !Task.isCancelled {
        let data = fileHandle.availableData
        guard !data.isEmpty else {
          return
        }
        await self.append(data)
      }
    }
  }

  func stop() {
    task?.cancel()
    task = nil
  }

  func snapshot() -> String? {
    guard !buffer.isEmpty else {
      return nil
    }

    let decoded = String(decoding: buffer, as: UTF8.self)
    return Self.redacted(decoded)
  }

  private func append(_ data: Data) {
    buffer.append(data)
    if buffer.count > Self.capacity {
      buffer.removeFirst(buffer.count - Self.capacity)
    }
  }

  private static func redacted(_ input: String) -> String {
    let patterns = [
      #"(?i)(bearer\s+)[^\s]+"#,
      #"(?i)((?:api[_-]?key|token|secret|password)\s*[:=]\s*)[^\s]+"#,
    ]
    return patterns.reduce(input) { value, pattern in
      value.replacingOccurrences(
        of: pattern,
        with: "$1[REDACTED]",
        options: .regularExpression
      )
    }
  }
}
