import Foundation

package enum CodexProcessProbeError: Error, LocalizedError, Sendable {
  case timedOut
  case outputLimitExceeded
  case cleanupTimedOut

  package var errorDescription: String? {
    switch self {
    case .timedOut: "Codex version probe exceeded its deadline."
    case .outputLimitExceeded: "Codex version probe exceeded its output capture limit."
    case .cleanupTimedOut: "Codex version probe cleanup could not be confirmed."
    }
  }
}

package struct CodexProcessProbeResult: Sendable {
  package let exit: CodexProcessExit
  package let stdout: Data
  package let stderr: Data
}

package enum CodexProcessProbe {
  package static func run(
    executableURL: URL, arguments: [String], environment: [String: String],
    workingDirectory: URL?, timeoutSeconds: Double, outputLimit: Int
  ) async throws -> CodexProcessProbeResult {
    guard timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 60, outputLimit > 0 else {
      throw CodexProcessFailure(description: "Invalid Codex version probe limits.")
    }
    let process = try await CodexProcess(
      executableURL: executableURL, arguments: arguments, environment: environment,
      workingDirectory: workingDirectory)
    let state = CodexProcessProbeState(deadline: .now() + timeoutSeconds + 5)
    // Reader tasks outlive caller cancellation only to drain and join owned IO.
    let stdout = Task.detached {
      await capture(process.standardOutput, process: process, state: state, limit: outputLimit)
    }
    let stderr = Task.detached {
      await capture(process.standardError, process: process, state: state, limit: outputLimit)
    }
    state.startDeadline {
      stdout.cancel()
      stderr.cancel()
    }
    defer { state.stopDeadline() }

    return try await withTaskCancellationHandler {
      var exit: CodexProcessExit?
      var failure: Error?
      var timedOut = false
      do {
        try process.standardInput.close()
        exit = try await process.waitForExit(until: .now() + timeoutSeconds)
        timedOut = exit == nil
      } catch { failure = error }
      state.beginCleanup()
      if timedOut || failure != nil {
        process.cancel()
        do {
          exit = try await process.waitForExit(until: .now() + .seconds(5))
          if exit == nil { failure = CodexProcessProbeError.cleanupTimedOut }
        } catch { failure = error }
      }
      let output = await stdout.value
      let error = await stderr.value
      if let failure { throw failure }
      if let pipeError = state.pipeError { throw pipeError }
      if state.overflow { throw CodexProcessProbeError.outputLimitExceeded }
      if timedOut { throw CodexProcessProbeError.timedOut }
      try Task.checkCancellation()
      guard let exit else { throw CodexProcessProbeError.cleanupTimedOut }
      return .init(exit: exit, stdout: output, stderr: error)
    } onCancel: {
      process.cancel()
    }
  }

  private static func capture(
    _ handle: FileHandle, process: CodexProcess, state: CodexProcessProbeState, limit: Int
  ) async -> Data {
    defer { try? handle.close() }
    var captured = Data()
    do {
      while let chunk = try await CodexProcessPipe.readChunk(from: handle) {
        let count = min(chunk.count, limit - captured.count)
        captured.append(contentsOf: chunk.prefix(count))
        if count < chunk.count {
          state.recordOverflow()
          process.cancel()
        }
      }
    } catch {
      state.recordPipeError(
        error is CancellationError ? CodexProcessProbeError.cleanupTimedOut : error)
      process.cancel()
    }
    return captured
  }
}

/// The lock covers failures and a shared deadline that cleanup may only shorten.
private final class CodexProcessProbeState: @unchecked Sendable {
  private let lock = NSLock()
  private var readError: Error?
  private var exceededLimit = false
  private var deadline: DispatchTime
  private var timer: (any DispatchSourceTimer)?

  init(deadline: DispatchTime) { self.deadline = deadline }

  func startDeadline(_ stopReading: @escaping @Sendable () -> Void) {
    lock.withLock {
      let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
      timer.setEventHandler(handler: stopReading)
      timer.schedule(deadline: deadline)
      self.timer = timer
      timer.resume()
    }
  }

  func stopDeadline() {
    let timer = lock.withLock {
      let timer = self.timer
      self.timer = nil
      return timer
    }
    timer?.cancel()
  }

  func beginCleanup() {
    lock.withLock {
      deadline = min(deadline, .now() + .seconds(5))
      timer?.schedule(deadline: deadline)
    }
  }

  var pipeError: Error? { lock.withLock { readError } }
  var overflow: Bool { lock.withLock { exceededLimit } }

  func recordOverflow() {
    lock.withLock { exceededLimit = true }
    beginCleanup()
  }
  func recordPipeError(_ error: Error) {
    lock.withLock { if readError == nil { readError = error } }
    beginCleanup()
  }
}
