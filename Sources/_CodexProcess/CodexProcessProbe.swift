import Foundation

#if os(Windows)
  import WinSDK
#endif

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
  /// Synchronous configuration validation; IO and native completion progress on
  /// blocking workers independently of the caller's executor.
  package static func run(
    executableURL: URL, arguments: [String], environment: [String: String],
    workingDirectory: URL?, timeoutSeconds: Double, outputLimit: Int
  ) throws -> CodexProcessProbeResult {
    guard timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 60, outputLimit > 0 else {
      throw CodexProcessFailure(description: "Invalid Codex version probe limits.")
    }
    let process = try CodexProcess(
      executableURL: executableURL, arguments: arguments, environment: environment,
      workingDirectory: workingDirectory)
    let state = CodexProcessProbeState(deadline: .now() + timeoutSeconds + 5)
    let readers = DispatchGroup()
    for (isStdout, handle) in [(true, process.standardOutput), (false, process.standardError)] {
      readers.enter()
      DispatchQueue.global(qos: .utility).async {
        defer {
          try? handle.close()
          readers.leave()
        }
        var captured = Data()
        do {
          while let chunk = try readChunk(from: handle, state: state) {
            let count = min(chunk.count, outputLimit - captured.count)
            captured.append(contentsOf: chunk.prefix(count))
            if count < chunk.count {
              state.recordOverflow()
              process.cancel()
            }
          }
        } catch {
          state.recordPipeError(error)
          process.cancel()
        }
        state.store(captured, isStdout: isStdout)
      }
    }

    var exit: CodexProcessExit?
    var failure: Error?
    var timedOut = false
    do {
      try process.standardInput.close()
      exit = try process.waitForExit(until: .now() + timeoutSeconds)
      timedOut = exit == nil
    } catch { failure = error }
    state.beginCleanup()
    if timedOut || failure != nil {
      process.cancel()
      do {
        exit = try process.waitForExit(until: .now() + .seconds(5))
        if exit == nil { failure = CodexProcessProbeError.cleanupTimedOut }
      } catch { failure = error }
    }
    // Each reader polls its own native handle and observes the shared cleanup
    // deadline. No original read operation survives this join, even after failure.
    readers.wait()
    let capture = state.snapshot()
    if let failure { throw failure }
    if let pipeError = capture.pipeError { throw pipeError }
    if capture.overflow { throw CodexProcessProbeError.outputLimitExceeded }
    if timedOut { throw CodexProcessProbeError.timedOut }
    guard let exit else { throw CodexProcessProbeError.cleanupTimedOut }
    return .init(exit: exit, stdout: capture.stdout, stderr: capture.stderr)
  }

  private static func readChunk(
    from handle: FileHandle, state: CodexProcessProbeState
  ) throws -> Data? {
    var bytes = [UInt8](repeating: 0, count: 16_384)
    while true {
      guard !state.readDeadlineElapsed else { throw CodexProcessProbeError.cleanupTimedOut }
      #if os(Windows)
        var available: DWORD = 0
        guard PeekNamedPipe(handle._handle, nil, 0, nil, &available, nil) else {
          let code = GetLastError()
          if code == DWORD(ERROR_BROKEN_PIPE) { return nil }
          throw CodexWindowsProcess.error("PeekNamedPipe", code: code)
        }
        if available == 0 {
          Thread.sleep(forTimeInterval: 0.01)
          continue
        }
        let count = min(available, DWORD(bytes.count))
        var received: DWORD = 0
        guard ReadFile(handle._handle, &bytes, count, &received, nil) else {
          let code = GetLastError()
          if code == DWORD(ERROR_BROKEN_PIPE) { return nil }
          throw CodexWindowsProcess.error("ReadFile", code: code)
        }
        return received == 0 ? nil : Data(bytes.prefix(Int(received)))
      #else
        var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, 10)
        if ready < 0 {
          if errno == EINTR { continue }
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if ready == 0 { continue }
        let count = bytes.withUnsafeMutableBytes {
          read(handle.fileDescriptor, $0.baseAddress, $0.count)
        }
        if count < 0 {
          if errno == EINTR { continue }
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return count == 0 ? nil : Data(bytes.prefix(count))
      #endif
    }
  }
}

private final class CodexProcessProbeState: @unchecked Sendable {
  struct Snapshot {
    var stdout = Data()
    var stderr = Data()
    var pipeError: Error?
    var overflow = false
  }

  private let lock = NSLock()
  private var deadline: DispatchTime
  private var capture = Snapshot()

  init(deadline: DispatchTime) { self.deadline = deadline }

  var readDeadlineElapsed: Bool { lock.withLock { DispatchTime.now() >= deadline } }

  func beginCleanup() {
    lock.withLock { deadline = min(deadline, .now() + .seconds(5)) }
  }

  func recordOverflow() {
    lock.withLock { capture.overflow = true }
    beginCleanup()
  }

  func recordPipeError(_ error: Error) {
    lock.withLock { if capture.pipeError == nil { capture.pipeError = error } }
    beginCleanup()
  }

  func store(_ data: Data, isStdout: Bool) {
    lock.withLock {
      if isStdout { capture.stdout = data } else { capture.stderr = data }
    }
  }

  func snapshot() -> Snapshot { lock.withLock { capture } }
}
