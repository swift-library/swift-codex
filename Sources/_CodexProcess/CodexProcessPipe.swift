import Foundation

#if os(Windows)
  import WinSDK
#elseif canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

package enum CodexProcessPipe {
  /// Drains readiness events into a bounded buffer independently of the consumer.
  /// The caller retains the handle until return, when native observation is detached.
  package static func readChunks(
    from handle: FileHandle, capacity: Int = 256 * 1_024,
    onChunk: (Data) async throws -> Void
  ) async throws {
    let reader = CodexPipeRead(handle: handle, capacity: capacity)
    do {
      while let chunk = try await reader.next() { try await onChunk(chunk) }
      await reader.close()
    } catch {
      await reader.close()
      throw error
    }
  }

  /// One partial read without read-ahead. The caller owns and serializes the handle.
  /// Cancellation detaches native observation before returning, so closing is safe.
  package static func readChunk(from handle: FileHandle, maximumBytes: Int = 16_384) async throws
    -> Data?
  {
    let reader = CodexPipeRead(handle: handle, capacity: maximumBytes, singleRead: true)
    do {
      let chunk = try await reader.next()
      await reader.close()
      return chunk
    } catch {
      await reader.close()
      throw error
    }
  }

  /// The caller serializes writes and retains the handle until the operation completes.
  package static func write(_ data: Data, to handle: FileHandle) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      // Isolate native write backpressure from exit and deadline callback queues.
      DispatchQueue(label: "swift-codex.pipe-write", qos: .utility).async {
        do {
          try handle.write(contentsOf: data)
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
}

/// All mutable state and native access belong to queue. A source retains this owner
/// until its cancellation handler has detached the handle and restored its flags.
private final class CodexPipeRead: @unchecked Sendable {
  private let queue = DispatchQueue(label: "swift-codex.pipe-read", qos: .utility)
  private let handle: FileHandle
  private let capacity: Int
  private let singleRead: Bool
  private var buffer = Data()
  private var continuation: CheckedContinuation<Data?, Error>?
  private var closeWaiters: [CheckedContinuation<Void, Never>] = []
  private var source: (any DispatchSourceProtocol)?
  private var suspended = false
  private var terminal: Result<Void, Error>?
  #if !os(Windows)
    private var originalFlags: Int32?
  #endif

  init(handle: FileHandle, capacity: Int, singleRead: Bool = false) {
    precondition(capacity > 0)
    self.handle = handle
    self.capacity = capacity
    self.singleRead = singleRead
  }

  func next() async throws -> Data? {
    try Task.checkCancellation()
    let chunk: Data? = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        queue.async {
          precondition(self.continuation == nil)
          self.continuation = continuation
          if self.source == nil, self.terminal == nil { self.start() }
          self.deliver()
        }
      }
    } onCancel: {
      self.queue.async { self.cancel() }
    }
    try Task.checkCancellation()
    return chunk
  }

  func close() async {
    await withCheckedContinuation { continuation in
      queue.async {
        self.closeWaiters.append(continuation)
        self.cancel()
      }
    }
  }

  private func start() {
    #if os(Windows)
      // Anonymous Foundation pipes do not support overlapped IO. Each timer
      // event drains all available bytes without reading beyond PeekNamedPipe.
      let source = DispatchSource.makeTimerSource(queue: queue)
      source.schedule(deadline: .now(), repeating: .milliseconds(10))
    #else
      let descriptor = handle.fileDescriptor
      let flags = fcntl(descriptor, F_GETFL)
      guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
        stop(.failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)))
        return
      }
      originalFlags = flags
      let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
    #endif
    self.source = source
    source.setEventHandler { self.readAvailable() }
    source.setCancelHandler {
      #if !os(Windows)
        if let flags = self.originalFlags {
          _ = fcntl(self.handle.fileDescriptor, F_SETFL, flags)
        }
      #endif
      self.source = nil
      self.deliver()
    }
    source.resume()
  }

  private func readAvailable() {
    guard terminal == nil else { return }
    var bytes = [UInt8](repeating: 0, count: min(16_384, capacity))
    while buffer.count < capacity {
      let maximum = min(bytes.count, capacity - buffer.count)
      #if os(Windows)
        var available: DWORD = 0
        guard PeekNamedPipe(handle._handle, nil, 0, nil, &available, nil) else {
          stopWindowsError(GetLastError())
          break
        }
        guard available > 0 else { break }
        var count: DWORD = 0
        let succeeded = bytes.withUnsafeMutableBytes {
          ReadFile(handle._handle, $0.baseAddress, min(available, DWORD(maximum)), &count, nil)
        }
        guard succeeded else {
          stopWindowsError(GetLastError())
          break
        }
        let readCount = Int(count)
      #else
        let readCount = bytes.withUnsafeMutableBytes {
          read(handle.fileDescriptor, $0.baseAddress, maximum)
        }
        if readCount < 0 {
          if errno == EINTR { continue }
          if errno != EAGAIN && errno != EWOULDBLOCK {
            stop(.failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)))
          }
          break
        }
      #endif
      if readCount == 0 {
        stop(.success(()))
        break
      }
      buffer.append(contentsOf: bytes.prefix(readCount))
    }
    if singleRead, !buffer.isEmpty { stop(.success(())) }
    // A full buffer pauses native readiness delivery, preserving pipe backpressure
    // without spinning. Consuming it resumes the same source, never a new task.
    if terminal == nil, buffer.count == capacity { setSuspended(true) }
    deliver()
  }

  #if os(Windows)
    private func stopWindowsError(_ code: DWORD) {
      if code == DWORD(ERROR_BROKEN_PIPE) {
        stop(.success(()))
      } else {
        stop(.failure(CodexWindowsProcess.error("ReadFile/PeekNamedPipe", code: code)))
      }
    }
  #endif

  private func setSuspended(_ value: Bool) {
    guard let source, suspended != value else { return }
    suspended = value
    if value { source.suspend() } else { source.resume() }
  }

  private func stop(_ result: Result<Void, Error>) {
    guard terminal == nil else { return }
    terminal = result
    // A suspended source must resume so its cancellation handler can run.
    setSuspended(false)
    source?.cancel()
  }

  private func cancel() {
    buffer.removeAll()
    stop(.failure(CancellationError()))
    deliver()
  }

  private func deliver() {
    if let continuation {
      if !buffer.isEmpty {
        let chunk = buffer
        buffer = Data()
        self.continuation = nil
        setSuspended(false)
        continuation.resume(returning: chunk)
      } else if let terminal, source == nil {
        self.continuation = nil
        continuation.resume(with: terminal.map { nil })
      }
    }
    if source == nil, terminal != nil {
      let waiters = closeWaiters
      closeWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
    }
  }
}
