import Foundation
import _CodexProcess

/// Owns the subprocess endpoints until native exit and every stderr read complete.
internal final class CodexMCPManagedSubprocess: @unchecked Sendable {
  let input: FileHandle?
  let output: FileHandle?
  let error: FileHandle?
  private let fixturePeerEndpoints: [FileHandle]
  private let process: CodexProcess?
  private let terminateHandler: @Sendable () async throws -> Void
  private let stderrCapture = CodexMCPStderrCapture()
  private let lock = NSLock()
  private var cleanup: Task<Void, Never>?

  init(process: CodexProcess) {
    input = process.standardInput
    output = process.standardOutput
    error = process.standardError
    self.process = process
    fixturePeerEndpoints = []
    terminateHandler = {
      process.cancel()
      _ = try await process.waitForExit()
    }
  }

  /// The injected fixture owns both pipe ends; live children retain only their ends.
  init(
    standardInput: Pipe? = nil,
    standardOutput: Pipe? = nil,
    standardError: Pipe? = nil,
    terminateHandler: @escaping @Sendable () async throws -> Void
  ) {
    input = standardInput?.fileHandleForWriting
    output = standardOutput?.fileHandleForReading
    error = standardError?.fileHandleForReading
    fixturePeerEndpoints = [
      standardInput?.fileHandleForReading, standardOutput?.fileHandleForWriting,
      standardError?.fileHandleForWriting,
    ].compactMap { $0 }
    process = nil
    self.terminateHandler = terminateHandler
  }

  deinit { process?.cancel() }

  func terminate() async throws {
    try await terminateHandler()
  }

  func startDrainingStderr() async {
    if let error { await stderrCapture.start(fileHandle: error) }
  }

  func stderrContext() async -> String? {
    await stderrCapture.snapshot()
  }

  /// Called after transport disconnect and process exit, before descriptor reuse.
  func closeIO() async {
    let task = lock.withLock {
      if let cleanup { return cleanup }
      let task = Task { [input, output, error, fixturePeerEndpoints, stderrCapture] in
        // Fixture writers must also close to let their blocked stderr reader finish.
        for endpoint in fixturePeerEndpoints { try? endpoint.close() }
        await stderrCapture.finish()
        try? input?.close()
        try? output?.close()
        try? error?.close()
      }
      cleanup = task
      return task
    }
    await task.value
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
      while true {
        do {
          guard let data = try await CodexProcessPipe.readChunk(from: fileHandle) else { return }
          await self.append(data)
        } catch { return }
      }
    }
  }

  func finish() async {
    let reading = task
    // The process has exited and all peer writers are closed; retain its final diagnostics.
    await reading?.value
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
