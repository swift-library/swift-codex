#if !os(Windows) && !canImport(Darwin)
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
          .success(
            .init(
              status: process.terminationStatus,
              wasSignalled: process.terminationReason == .uncaughtSignal)))
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

    func waitForExit() async throws -> CodexProcessExit { try await completion.wait() }

    func waitForExit(until deadline: DispatchTime) throws -> CodexProcessExit? {
      try completion.wait(until: deadline)
    }
  }

#endif
