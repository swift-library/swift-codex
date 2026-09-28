import Foundation
import _CodexProcess

struct CodexExecPreparedLaunch: Equatable, Sendable {
  var kind: CodexExecLaunchKind
  var executableURL: URL
  var arguments: [String]
  var environment: [String: String]
  var workingDirectory: URL?
  var standardInput: Data?
  var outputLimits: CodexExecOutputLimits = .init()
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
  var outputCapture: CodexExecOutputCapture = .init()
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
    if Task.isCancelled { throw CodexExecLaunchCancelled() }
    let process = try CodexProcess(
      executableURL: launch.executableURL, arguments: launch.arguments,
      environment: launch.environment, workingDirectory: launch.workingDirectory)
    let stdout = process.standardOutput
    let stderr = process.standardError
    let stdin = process.standardInput
    let stdoutCollector = CodexExecStdoutCollector()
    let stdoutContinuationState = CodexExecStdoutContinuationState()

    let stdoutLines = AsyncThrowingStream<String, Error> { continuation in
      stdoutContinuationState.set(continuation)
      continuation.onTermination = { termination in
        guard case .cancelled = termination else {
          return
        }

        process.cancel()
      }
    }

    let stderrReaderTask = Task.detached(priority: nil) {
      defer { try? stderr.close() }
      return try await readStderr(from: stderr, limit: launch.outputLimits.stderrBytes)
    }

    let stdinWriterTask = Task.detached(priority: nil) {
      defer { try? stdin.close() }
      if let input = launch.standardInput { try await CodexProcessPipe.write(input, to: stdin) }
    }

    let stdoutReaderTask = Task.detached(priority: nil) {
      defer { try? stdout.close() }
      do {
        let droppedBytes = try await readStdoutLines(
          from: stdout, limits: launch.outputLimits
        ) { line in
          await stdoutCollector.append(line)
          stdoutContinuationState.yield(line)
        }
        if droppedBytes > 0 {
          stdoutContinuationState.finish(
            throwing: CodexExecError.outputCaptureLimitExceeded(
              partialObservation: .init(outputCapture: .init(stdoutDroppedBytes: droppedBytes))))
        } else {
          stdoutContinuationState.finish()
        }
        return droppedBytes
      } catch {
        stdoutContinuationState.finish(throwing: error)
        throw error
      }
    }

    return CodexExecLaunchedProcess(
      stdoutLines: stdoutLines,
      waitForOutput: {
        try await waitForProcessOutput(
          process: process,
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

private func waitForProcessOutput(
  process: CodexProcess,
  stdoutCollector: CodexExecStdoutCollector,
  stdinWriterTask: Task<Void, Error>,
  stdoutReaderTask: Task<Int64, Error>,
  stderrReaderTask: Task<CodexExecCapturedStderr, Error>
) async throws -> CodexExecProcessOutput {
  try await withTaskCancellationHandler {
    let exit: Result<CodexProcessExit, Error>
    do { exit = .success(try await process.waitForExit()) } catch { exit = .failure(error) }
    // Every original IO task settles before any error leaves process ownership.
    let inputResult = await stdinWriterTask.result
    let stdoutResult = await stdoutReaderTask.result
    let stderrResult = await stderrReaderTask.result
    let termination = try exit.get()
    let stdoutDroppedBytes = try stdoutResult.get()
    let stderr = try stderrResult.get()
    let stdoutText = await stdoutCollector.textSnapshot()
    let output = CodexExecProcessOutput(
      exitStatus: termination.wasSignalled ? nil : termination.status,
      terminationSignal: termination.wasSignalled ? termination.status : nil,
      standardOutput: Data(stdoutText.utf8), standardError: stderr.data,
      outputCapture: .init(
        stdoutDroppedBytes: stdoutDroppedBytes, stderrDroppedBytes: stderr.droppedBytes))
    if process.cancellationWasRequested { throw CodexExecLaunchCancelled(processOutput: output) }
    // Native failure remains primary; a successful child cannot hide lost input.
    if termination.status == 0, !termination.wasSignalled { try inputResult.get() }
    return output
  } onCancel: {
    process.cancel()
  }
}

private func readStdoutLines(
  from handle: FileHandle,
  limits: CodexExecOutputLimits,
  onLine: (String) async throws -> Void
) async throws -> Int64 {
  var parser = CodexExecBoundedLineParser(limits: limits)
  while let chunk = try await CodexProcessPipe.readChunk(from: handle) {
    for byte in chunk {
      if let line = parser.append(byte) { try await onLine(line) }
    }
  }
  if let line = parser.finish() { try await onLine(line) }
  return parser.droppedBytes
}

private func readStderr(from handle: FileHandle, limit: Int) async throws -> CodexExecCapturedStderr
{
  var capture = CodexExecCapturedStderr(data: Data(), droppedBytes: 0)
  while let chunk = try await CodexProcessPipe.readChunk(from: handle) {
    let retainedCount = min(chunk.count, limit - capture.data.count)
    capture.data.append(contentsOf: chunk.prefix(retainedCount))
    capture.droppedBytes += Int64(chunk.count - retainedCount)
  }
  return capture
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
