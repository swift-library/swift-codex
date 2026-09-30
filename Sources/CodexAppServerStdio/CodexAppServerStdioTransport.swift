import CodexAppServerRuntime
import Foundation
import _CodexProcess

public final class CodexAppServerStdioTransport: CodexAppServerLinePeer {
  /// The root process's native termination after owned cleanup and pipe operations finish.
  public enum Termination: Equatable, Sendable {
    /// A native exit code. Windows preserves the unsigned DWORD's bit pattern.
    case exited(Int32)
    /// The POSIX signal that terminated the process.
    case signalled(Int32)
  }

  public let inboundLines: AsyncThrowingStream<String, Error>

  /// The launched process ID for diagnostics. Windows preserves its DWORD bit pattern.
  /// A numeric ID is not authority to signal or adopt a process after this lifetime ends.
  public var processIdentifier: Int32 { process.processIdentifier }

  private let process: CodexProcess
  private let writer: CodexAppServerFileHandleLineWriter
  private let lifecycle: Task<Result<CodexProcessExit, Error>, Never>

  public init(configuration: CodexAppServerStdioConfiguration = .init()) throws {
    guard configuration.maximumMessageBytes > 0,
      configuration.maximumMessageBytes <= CodexAppServerBufferLimits.bytes
    else {
      throw CodexAppServerStdioError.invalidConfiguration(
        "Maximum message bytes must be positive and no greater than 16 MiB.")
    }
    let compatibility = try configuration.validateBinaryCompatibility()
    let process: CodexProcess
    do {
      process = try CodexProcess(
        executableURL: compatibility.resolution.executableURL,
        arguments: configuration.arguments,
        environment: configuration.environment ?? ProcessInfo.processInfo.environment,
        workingDirectory: configuration.workingDirectoryURL)
    } catch {
      throw CodexAppServerStdioError.launchFailure(error.localizedDescription)
    }
    let inboundChannel = CodexAppServerAsyncThrowingChannel<String>()
    let writer = CodexAppServerFileHandleLineWriter(
      handle: process.standardInput, maximumMessageBytes: configuration.maximumMessageBytes)
    let stdout = process.standardOutput
    let stderr = process.standardError
    let stderrDiagnostic = CodexAppServerProcessDiagnostic()
    let stdoutReader = Task.detached(priority: nil) {
      defer { try? stdout.close() }
      do {
        try await CodexAppServerPipeReader.readLines(
          from: stdout, maximumMessageBytes: configuration.maximumMessageBytes
        ) {
          try inboundChannel.yield($0, byteCount: $0.utf8.count)
        }
      } catch {
        process.cancel()
        throw error
      }
    }
    let stderrReader = Task.detached(priority: nil) {
      defer { try? stderr.close() }
      while let chunk = try? await CodexProcessPipe.readChunk(from: stderr) {
        stderrDiagnostic.append(chunk)
      }
    }
    self.inboundLines = inboundChannel.stream
    self.process = process
    self.writer = writer
    // One uncancelled owner joins exit and every pipe task, including natural exit.
    // Concurrent close callers await this same task.
    self.lifecycle = Task.detached(priority: nil) {
      let exit: Result<CodexProcessExit, Error>
      do { exit = .success(try await process.waitForExit()) } catch { exit = .failure(error) }
      await writer.close()
      let output = await stdoutReader.result
      await stderrReader.value
      do {
        let termination = try exit.get()
        try output.get()
        if !process.cancellationWasRequested,
          termination.wasSignalled || termination.status != 0
        {
          throw CodexAppServerStdioError.processTerminated(
            exitStatus: termination.wasSignalled ? nil : termination.status,
            diagnostic: stderrDiagnostic.snapshot())
        }
        inboundChannel.finish()
      } catch {
        inboundChannel.finish(throwing: error)
      }
      return exit
    }
  }

  deinit {
    writer.closeAdmission()
    process.cancel()
  }

  public func sendLine(_ line: String) async throws {
    do {
      try await writer.write(line)
    } catch let error as CodexAppServerConnectionFoundation.FoundationError {
      // These failures reject an unsent frame before native IO begins.
      throw error
    } catch CodexAppServerStdioError.closed {
      // An unsent write after input EOF must not interrupt the child's final work.
      throw CodexAppServerStdioError.closed
    } catch {
      process.cancel()
      _ = await lifecycle.value
      throw error
    }
  }

  public func close() async {
    writer.closeAdmission()
    process.cancel()
    _ = await lifecycle.value
  }

  /// Rejects new writes, drains accepted writes, then closes stdin without terminating the child.
  /// Concurrent or cancelled callers join the same input closure. A blocked child may prevent
  /// this method from returning; use `close()` to force termination and join cleanup.
  /// Native input-close failure terminates and joins the process before throwing.
  public func finishInput() async throws {
    do {
      try await writer.finish().value
    } catch {
      process.cancel()
      _ = await lifecycle.value
      throw error
    }
  }

  /// Waits for native cleanup and every owned pipe operation without consuming messages.
  /// Concurrent or cancelled waiters observe the same lifetime; they do not terminate it.
  /// Native cleanup failure throws. Framing and read failures remain on `inboundLines`.
  public func waitForExit() async throws -> Termination {
    let result = try await lifecycle.value.get()
    return result.wasSignalled ? .signalled(result.status) : .exited(result.status)
  }
}

final class CodexAppServerFileHandleLineWriter: @unchecked Sendable {
  // Admission and queue submission share a lock. Only the serial queue writes or
  // closes the handle, so closing cannot race with a syscall or interleave frames.
  private let lock = NSLock()
  private enum State { case open, finishing, cancelled }
  private var state = State.open
  private var inputClosure: Task<Void, Error>?
  private var admittedMessages = 0
  private var admittedBytes = 0
  private let maximumMessages: Int
  private let maximumBytes: Int
  private let codec: CodexAppServerConnectionFoundation.StdioFrameCodec
  private let queue = DispatchQueue(label: "swift-codex.app-server.stdin", qos: .utility)
  private let handle: FileHandle

  init(
    handle: FileHandle,
    maximumMessages: Int = CodexAppServerBufferLimits.messages,
    maximumBytes: Int = CodexAppServerBufferLimits.bytes,
    maximumMessageBytes: Int = CodexAppServerBufferLimits.bytes
  ) {
    precondition(maximumMessages > 0 && maximumBytes > 0)
    self.handle = handle
    self.maximumMessages = maximumMessages
    self.maximumBytes = maximumBytes
    self.codec = .init(maximumFrameBytes: maximumMessageBytes)
  }

  func write(_ line: String) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      write(line) { continuation.resume(with: $0) }
    }
  }

  func write(_ line: String, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
    let byteCount = line.utf8.count
    lock.withLock {
      guard state == .open else {
        completion(.failure(CodexAppServerStdioError.closed))
        return
      }
      guard admittedMessages < maximumMessages, byteCount <= maximumBytes - admittedBytes else {
        completion(
          .failure(
            CodexAppServerConnectionFoundation.FoundationError.bufferLimitExceeded(
              maximumMessages: maximumMessages, maximumBytes: maximumBytes)))
        return
      }
      let data: Data
      do {
        data = try codec.encodeOutgoingLine(line)
      } catch {
        completion(.failure(error))
        return
      }
      admittedMessages += 1
      admittedBytes += byteCount
      queue.async {
        let result: Result<Void, Error> = Result {
          guard self.lock.withLock({ self.state != .cancelled }) else {
            throw CodexAppServerStdioError.closed
          }
          try self.handle.write(contentsOf: data)
        }
        self.lock.withLock {
          self.admittedMessages -= 1
          self.admittedBytes -= byteCount
          if case .failure = result { self.state = .cancelled }
        }
        completion(result)
      }
    }
  }

  func closeAdmission() { lock.withLock { state = .cancelled } }

  func close() async {
    closeAdmission()
    try? await finish().value
  }

  func finish() -> Task<Void, Error> {
    lock.withLock {
      if let inputClosure { return inputClosure }
      if state == .open { state = .finishing }
      // Admission is closed before scheduling EOF. Every accepted write was
      // already submitted under this lock, and only this task closes the handle.
      let closure = Task.detached { [handle, queue] in
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Void, Error>) in
          queue.async {
            continuation.resume(with: Result { try handle.close() })
          }
        }
      }
      inputClosure = closure
      return closure
    }
  }
}
