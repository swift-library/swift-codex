import CodexAppServerRuntime
import Darwin
import Foundation

public final class CodexAppServerStdioTransport: CodexAppServerLinePeer, @unchecked Sendable {
  public let inboundLines: AsyncThrowingStream<String, Error>

  private let processState: CodexAppServerProcessState
  private let writer: CodexAppServerFileHandleLineWriter
  private let inboundChannel: CodexAppServerAsyncThrowingChannel<String>
  private let stdoutReaderTask: Task<Void, Never>
  private let stderrReaderTask: Task<Void, Never>

  public init(configuration: CodexAppServerStdioConfiguration = .init()) throws {
    let process = Process()
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let processState = CodexAppServerProcessState(process: process)
    let inboundChannel = CodexAppServerAsyncThrowingChannel<String>()
    let writer = CodexAppServerFileHandleLineWriter(handle: stdinPipe.fileHandleForWriting)
    let compatibility = try configuration.validateBinaryCompatibility()

    process.executableURL = compatibility.resolution.executableURL
    process.arguments = configuration.arguments
    if let environment = configuration.environment {
      process.environment = environment
    }
    process.currentDirectoryURL = configuration.workingDirectoryURL
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    process.terminationHandler = { _ in
      processState.markExited()
    }

    do {
      try process.run()
      processState.markStarted()
    } catch {
      throw CodexAppServerStdioError.launchFailure(error.localizedDescription)
    }

    self.inboundLines = inboundChannel.stream
    self.processState = processState
    self.writer = writer
    self.inboundChannel = inboundChannel
    self.stdoutReaderTask = Task.detached(priority: nil) {
      do {
        try await CodexAppServerStdioTransport.readLines(
          from: stdoutPipe.fileHandleForReading
        ) { line in
          inboundChannel.yield(line)
        }
        inboundChannel.finish()
      } catch {
        inboundChannel.finish(throwing: error)
      }
    }
    self.stderrReaderTask = Task.detached(priority: nil) {
      _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    }
  }

  public func sendLine(_ line: String) async throws {
    try await writer.write(line)
  }

  public func close() async {
    stdoutReaderTask.cancel()
    stderrReaderTask.cancel()
    await writer.close()
    processState.requestCancellation()
    inboundChannel.finish()
  }

  private static func readLines(
    from handle: FileHandle,
    onLine: (String) async throws -> Void
  ) async throws {
    let duplicatedFD = dup(handle.fileDescriptor)
    guard duplicatedFD >= 0 else {
      throw CodexAppServerStdioError.launchFailure("Unable to duplicate stdout file descriptor.")
    }

    guard let file = fdopen(duplicatedFD, "r") else {
      Darwin.close(duplicatedFD)
      throw CodexAppServerStdioError.launchFailure("Unable to open stdout stream.")
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
      if Task.isCancelled {
        break
      }

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
}

private actor CodexAppServerFileHandleLineWriter {
  private var isClosed = false
  private let handle: FileHandle

  init(handle: FileHandle) {
    self.handle = handle
  }

  func write(_ line: String) throws {
    guard !isClosed else {
      throw CodexAppServerStdioError.closed
    }

    let data = try CodexAppServerConnectionFoundation.StdioFrameCodec()
      .encodeOutgoingLine(line)
    handle.write(data)
  }

  func close() {
    guard !isClosed else {
      return
    }

    isClosed = true
    handle.closeFile()
  }
}

private final class CodexAppServerProcessState: @unchecked Sendable {
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

  private func terminateProcess() {
    guard process.isRunning else {
      return
    }

    process.terminate()
  }
}
