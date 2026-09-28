#if !os(Windows)
  import Foundation

  final class CodexFoundationProcess: @unchecked Sendable {
    private let process: Process
    // Foundation owns native process access; this lock serializes our lifecycle flags.
    private let lock = NSLock()
    private var cancelled = false
    private var exited = false
    private let completion = CodexProcessCompletion()

    init(
      executableURL: URL, arguments: [String], environment: [String: String],
      workingDirectory: URL?, input: FileHandle, output: FileHandle, error: FileHandle
    ) throws {
      let process = Process()
      self.process = process
      process.executableURL = executableURL
      process.arguments = arguments
      process.environment = environment
      process.currentDirectoryURL = workingDirectory
      process.standardInput = input
      process.standardOutput = output
      process.standardError = error
      let completion = self.completion
      process.terminationHandler = { [weak self] process in
        if let self { self.lock.withLock { self.exited = true } }
        completion.finish(
          .init(
            status: process.terminationStatus,
            wasSignalled: process.terminationReason == .uncaughtSignal))
      }
      try process.run()
    }

    var cancellationWasRequested: Bool { lock.withLock { cancelled } }

    func cancel() {
      let shouldTerminate = lock.withLock {
        guard !exited, !cancelled else { return false }
        cancelled = true
        return true
      }
      if shouldTerminate, process.isRunning { process.terminate() }
    }

    func waitForExit() async throws -> CodexProcessExit { await completion.wait() }
  }

  /// Exit waiters remain owned until the original process callback settles them.
  private final class CodexProcessCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var result: CodexProcessExit?
    private var waiters: [CheckedContinuation<CodexProcessExit, Never>] = []

    func wait() async -> CodexProcessExit {
      await withCheckedContinuation { continuation in
        let completed: CodexProcessExit? = lock.withLock {
          if let result = self.result { return result }
          waiters.append(continuation)
          return nil
        }
        if let completed { continuation.resume(returning: completed) }
      }
    }

    func finish(_ result: CodexProcessExit) {
      let pending: [CheckedContinuation<CodexProcessExit, Never>] = lock.withLock {
        guard self.result == nil else { return [] }
        self.result = result
        let pending = waiters
        waiters.removeAll()
        return pending
      }
      for waiter in pending { waiter.resume(returning: result) }
    }
  }
#endif
