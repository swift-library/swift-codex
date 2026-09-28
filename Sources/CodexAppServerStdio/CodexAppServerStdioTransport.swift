import CodexAppServerRuntime
import Foundation
import _CodexProcess

public final class CodexAppServerStdioTransport: CodexAppServerLinePeer {
  public let inboundLines: AsyncThrowingStream<String, Error>

  private let process: CodexProcess
  private let writer: CodexAppServerFileHandleLineWriter
  private let lifecycle: Task<Void, Never>

  public init(configuration: CodexAppServerStdioConfiguration = .init()) throws {
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
    let writer = CodexAppServerFileHandleLineWriter(handle: process.standardInput)
    let stdout = process.standardOutput
    let stderr = process.standardError
    let stdoutReader = Task.detached(priority: nil) {
      defer { try? stdout.close() }
      do {
        try await CodexAppServerPipeReader.readLines(from: stdout) {
          try inboundChannel.yield($0, byteCount: $0.utf8.count)
        }
      } catch {
        process.cancel()
        throw error
      }
    }
    let stderrReader = Task.detached(priority: nil) {
      defer { try? stderr.close() }
      await CodexAppServerPipeReader.discard(from: stderr)
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
        _ = try exit.get()
        try output.get()
        inboundChannel.finish()
      } catch {
        inboundChannel.finish(throwing: error)
      }
    }
  }

  deinit {
    writer.closeAdmission()
    process.cancel()
  }

  public func sendLine(_ line: String) async throws { try await writer.write(line) }

  public func close() async {
    writer.closeAdmission()
    process.cancel()
    await lifecycle.value
  }
}

final class CodexAppServerFileHandleLineWriter: @unchecked Sendable {
  // Admission and queue submission share a lock. Only the serial queue writes or
  // closes the handle, so closing cannot race with a syscall or interleave frames.
  private let lock = NSLock()
  private var isOpen = true
  private var admittedMessages = 0
  private var admittedBytes = 0
  private let maximumMessages: Int
  private let maximumBytes: Int
  private let queue = DispatchQueue(label: "swift-codex.app-server.stdin", qos: .utility)
  private let handle: FileHandle

  init(
    handle: FileHandle,
    maximumMessages: Int = CodexAppServerBufferLimits.messages,
    maximumBytes: Int = CodexAppServerBufferLimits.bytes
  ) {
    precondition(maximumMessages > 0 && maximumBytes > 0)
    self.handle = handle
    self.maximumMessages = maximumMessages
    self.maximumBytes = maximumBytes
  }

  func write(_ line: String) async throws {
    let byteCount = line.utf8.count
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      lock.withLock {
        guard isOpen else {
          continuation.resume(throwing: CodexAppServerStdioError.closed)
          return
        }
        guard admittedMessages < maximumMessages, byteCount <= maximumBytes - admittedBytes else {
          continuation.resume(
            throwing: CodexAppServerConnectionFoundation.FoundationError.bufferLimitExceeded(
              maximumMessages: maximumMessages, maximumBytes: maximumBytes))
          return
        }
        let data: Data
        do {
          data = try CodexAppServerConnectionFoundation.StdioFrameCodec().encodeOutgoingLine(line)
        } catch {
          continuation.resume(throwing: error)
          return
        }
        admittedMessages += 1
        admittedBytes += byteCount
        queue.async {
          let result: Result<Void, Error> = Result {
            guard self.lock.withLock({ self.isOpen }) else {
              throw CodexAppServerStdioError.closed
            }
            try self.handle.write(contentsOf: data)
          }
          self.lock.withLock {
            self.admittedMessages -= 1
            self.admittedBytes -= byteCount
            if case .failure = result { self.isOpen = false }
          }
          continuation.resume(with: result)
        }
      }
    }
  }

  func closeAdmission() { lock.withLock { isOpen = false } }

  func close() async {
    closeAdmission()
    await withCheckedContinuation { continuation in
      queue.async {
        try? self.handle.close()
        continuation.resume()
      }
    }
  }
}
