import Foundation

struct CodexExecPreparedLaunch: Equatable, Sendable {
  var kind: CodexExecLaunchKind
  var executableURL: URL
  var arguments: [String]
  var environment: [String: String]
  var workingDirectory: URL?
  var standardInput: Data?
}

enum CodexExecLaunchKind: Equatable, Sendable {
  case run(CodexExecRunRequest)
  case resume(CodexExecResumeRequest)
}

struct CodexExecProcessOutput: Equatable, Sendable {
  var exitStatus: Int32?
  var terminationSignal: Int32?
  var standardOutput: Data
  var standardError: Data
}

struct CodexExecLaunchCancelled: Error, Sendable {
  var processOutput: CodexExecProcessOutput?

  init(processOutput: CodexExecProcessOutput? = nil) {
    self.processOutput = processOutput
  }
}

struct CodexExecLaunchedProcess: Sendable {
  var stdoutLines: AsyncThrowingStream<String, Error>
  var waitForOutput: @Sendable () async throws -> CodexExecProcessOutput
  var collectedStdoutLines: @Sendable () async -> [String]
}

protocol CodexExecLaunching: Sendable {
  func launch(_ launch: CodexExecPreparedLaunch) async throws -> CodexExecLaunchedProcess
}

struct CodexExecExecutableResolver {
  func resolveExecutable(using configuration: CodexExecLaunchConfiguration) throws -> URL {
    if let executableURL = configuration.executableURL {
      return executableURL
    }

    let environment = configuration.environmentOverride ?? ProcessInfo.processInfo.environment
    let pathValue = environment["PATH"] ?? ""

    for directory in pathValue.split(separator: ":") {
      let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("codex")
      if FileManager.default.isExecutableFile(atPath: candidate.path) {
        return candidate
      }
    }

    throw CodexExecError.launchFailure(
      description: "Unable to resolve the `codex` executable from PATH.")
  }
}

struct CodexExecSystemLauncher: CodexExecLaunching {
  func launch(_ launch: CodexExecPreparedLaunch) async throws -> CodexExecLaunchedProcess {
    let process = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let stdinPipe = Pipe()
    let processState = CodexExecProcessState(process: process)
    let termination = CodexExecProcessTermination()
    let stdoutCollector = CodexExecStdoutCollector()
    let stdoutContinuationState = CodexExecStdoutContinuationState()
    let stdoutReaderTaskBox = CodexExecTaskBox<Void, Error>()
    let stdinWriterTaskBox = CodexExecTaskBox<Void, Never>()

    configure(
      process,
      for: launch,
      stdoutPipe: stdoutPipe,
      stderrPipe: stderrPipe,
      stdinPipe: stdinPipe
    )
    process.terminationHandler = { terminatedProcess in
      processState.markExited()
      termination.store(
        status: terminatedProcess.terminationStatus,
        reason: terminatedProcess.terminationReason
      )
    }

    let stdoutLines = AsyncThrowingStream<String, Error> { continuation in
      stdoutContinuationState.set(continuation)
      continuation.onTermination = { termination in
        guard case .cancelled = termination else {
          return
        }

        stdoutReaderTaskBox.cancel()
        stdinWriterTaskBox.cancel()
        processState.requestCancellation()
      }
    }

    let stderrReaderTask = Task.detached(priority: nil) {
      stderrPipe.fileHandleForReading.readDataToEndOfFile()
    }

    do {
      try start(process)
      processState.markStarted()
    } catch {
      stdoutContinuationState.finish(throwing: error)
      stderrReaderTask.cancel()
      throw error
    }

    let stdinWriterTask = Task.detached(priority: nil) {
      writeStandardInput(for: launch, to: stdinPipe)
    }
    stdinWriterTaskBox.set(stdinWriterTask)

    let stdoutReaderTask = Task.detached(priority: nil) {
      do {
        try await readStdoutLines(from: stdoutPipe.fileHandleForReading) { line in
          await stdoutCollector.append(line)
          stdoutContinuationState.yield(line)
        }
        stdoutContinuationState.finish()
      } catch {
        stdoutContinuationState.finish(throwing: error)
        throw error
      }
    }
    stdoutReaderTaskBox.set(stdoutReaderTask)

    return CodexExecLaunchedProcess(
      stdoutLines: stdoutLines,
      waitForOutput: {
        try await waitForProcessOutput(
          processState: processState,
          termination: termination,
          stdoutCollector: stdoutCollector,
          stdinWriterTask: stdinWriterTask,
          stdoutReaderTask: stdoutReaderTask,
          stderrReaderTask: stderrReaderTask
        )
      },
      collectedStdoutLines: {
        await stdoutCollector.snapshot()
      }
    )
  }
}

private func configure(
  _ process: Process,
  for launch: CodexExecPreparedLaunch,
  stdoutPipe: Pipe,
  stderrPipe: Pipe,
  stdinPipe: Pipe
) {
  process.executableURL = launch.executableURL
  process.arguments = launch.arguments
  process.environment = launch.environment
  process.currentDirectoryURL = launch.workingDirectory
  process.standardOutput = stdoutPipe
  process.standardError = stderrPipe

  if launch.standardInput != nil {
    process.standardInput = stdinPipe
  }
}

private func start(_ process: Process) throws {
  do {
    try process.run()
  } catch {
    throw CodexExecError.launchFailure(description: error.localizedDescription)
  }
}

private func writeStandardInput(
  for launch: CodexExecPreparedLaunch,
  to stdinPipe: Pipe
) {
  guard let standardInput = launch.standardInput else {
    stdinPipe.fileHandleForWriting.closeFile()
    return
  }

  stdinPipe.fileHandleForWriting.write(standardInput)
  stdinPipe.fileHandleForWriting.closeFile()
}

private func waitForProcessOutput(
  processState: CodexExecProcessState,
  termination: CodexExecProcessTermination,
  stdoutCollector: CodexExecStdoutCollector,
  stdinWriterTask: Task<Void, Never>,
  stdoutReaderTask: Task<Void, Error>,
  stderrReaderTask: Task<Data, Never>
) async throws -> CodexExecProcessOutput {
  let output = try await withTaskCancellationHandler {
    let terminationResult = await termination.wait()
    await stdinWriterTask.value

    do {
      try await stdoutReaderTask.value
    } catch is CancellationError {
      // Process cancellation will be surfaced after output capture.
    } catch {
      throw CodexExecError.launchFailure(description: error.localizedDescription)
    }

    let stderrData = await stderrReaderTask.value
    let stdoutText = await stdoutCollector.textSnapshot()
    let processOutput = makeProcessOutput(
      terminationResult: terminationResult,
      standardOutput: Data(stdoutText.utf8),
      standardError: stderrData
    )

    if processState.cancellationWasRequested() {
      throw CodexExecLaunchCancelled(processOutput: processOutput)
    }

    return processOutput
  } onCancel: {
    processState.requestCancellation()
  }

  return output
}

private func makeProcessOutput(
  terminationResult: (status: Int32, reason: Process.TerminationReason),
  standardOutput: Data,
  standardError: Data
) -> CodexExecProcessOutput {
  switch terminationResult.reason {
  case .exit:
    return CodexExecProcessOutput(
      exitStatus: terminationResult.status,
      terminationSignal: nil,
      standardOutput: standardOutput,
      standardError: standardError
    )
  case .uncaughtSignal:
    return CodexExecProcessOutput(
      exitStatus: nil,
      terminationSignal: terminationResult.status,
      standardOutput: standardOutput,
      standardError: standardError
    )
  @unknown default:
    return CodexExecProcessOutput(
      exitStatus: nil,
      terminationSignal: nil,
      standardOutput: standardOutput,
      standardError: standardError
    )
  }
}

private func readStdoutLines(
  from handle: FileHandle,
  onLine: (String) async throws -> Void
) async throws {
  let duplicatedFD = dup(handle.fileDescriptor)
  guard duplicatedFD >= 0 else {
    throw CodexExecError.launchFailure(description: "Unable to duplicate stdout file descriptor.")
  }

  guard let file = fdopen(duplicatedFD, "r") else {
    close(duplicatedFD)
    throw CodexExecError.launchFailure(description: "Unable to open stdout stream.")
  }

  defer {
    fclose(file)
  }

  var linePointer: UnsafeMutablePointer<CChar>?
  var lineCapacity: Int = 0
  defer {
    free(linePointer)
  }

  while true {
    let readCount = getline(&linePointer, &lineCapacity, file)
    if readCount == -1 {
      break
    }

    guard let linePointer else {
      continue
    }

    var line = String(cString: linePointer)
    while line.hasSuffix("\n") || line.hasSuffix("\r") {
      line.removeLast()
    }

    try await onLine(line)
  }
}

private actor CodexExecStdoutCollector {
  private var lines: [String] = []

  func append(_ line: String) {
    lines.append(line)
  }

  func snapshot() -> [String] {
    lines
  }

  func textSnapshot() -> String {
    lines.joined(separator: "\n")
  }
}

private final class CodexExecStdoutContinuationState: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: AsyncThrowingStream<String, Error>.Continuation?

  func set(_ continuation: AsyncThrowingStream<String, Error>.Continuation) {
    lock.lock()
    self.continuation = continuation
    lock.unlock()
  }

  func yield(_ line: String) {
    lock.lock()
    let continuation = self.continuation
    lock.unlock()
    continuation?.yield(line)
  }

  func finish() {
    lock.lock()
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation?.finish()
  }

  func finish(throwing error: Error) {
    lock.lock()
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation?.finish(throwing: error)
  }
}

private final class CodexExecTaskBox<Success: Sendable, Failure: Error>: @unchecked Sendable {
  private let lock = NSLock()
  private var task: Task<Success, Failure>?

  func set(_ task: Task<Success, Failure>) {
    lock.lock()
    self.task = task
    lock.unlock()
  }

  func cancel() {
    lock.lock()
    let task = self.task
    lock.unlock()
    task?.cancel()
  }
}

private final class CodexExecProcessTermination: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation:
    CheckedContinuation<(status: Int32, reason: Process.TerminationReason), Never>?
  private var storedResult: (status: Int32, reason: Process.TerminationReason)?

  func wait() async -> (status: Int32, reason: Process.TerminationReason) {
    if let storedResult = currentResult() {
      return storedResult
    }

    return await withCheckedContinuation { continuation in
      lock.lock()
      if let storedResult {
        lock.unlock()
        continuation.resume(returning: storedResult)
      } else {
        self.continuation = continuation
        lock.unlock()
      }
    }
  }

  func store(status: Int32, reason: Process.TerminationReason) {
    lock.lock()
    let result = (status: status, reason: reason)
    if let continuation {
      self.continuation = nil
      storedResult = result
      lock.unlock()
      continuation.resume(returning: result)
    } else {
      storedResult = result
      lock.unlock()
    }
  }

  private func currentResult() -> (status: Int32, reason: Process.TerminationReason)? {
    lock.lock()
    defer { lock.unlock() }
    return storedResult
  }
}

private final class CodexExecProcessState: @unchecked Sendable {
  private let lock = NSLock()
  private let process: Process
  private var didStart = false
  private var didExit = false
  private var didRequestCancellation = false

  init(process: Process) {
    self.process = process
  }

  func markStarted() {
    let shouldTerminate: Bool
    lock.lock()
    didStart = true
    shouldTerminate = didRequestCancellation && !didExit
    lock.unlock()

    if shouldTerminate {
      terminateProcess()
    }
  }

  func markExited() {
    lock.lock()
    didExit = true
    lock.unlock()
  }

  func requestCancellation() {
    let shouldTerminate: Bool
    lock.lock()
    if didExit {
      lock.unlock()
      return
    }
    didRequestCancellation = true
    shouldTerminate = didStart
    lock.unlock()

    if shouldTerminate {
      terminateProcess()
    }
  }

  func cancellationWasRequested() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return didRequestCancellation
  }

  private func terminateProcess() {
    guard process.isRunning else {
      return
    }

    process.terminate()
  }
}
