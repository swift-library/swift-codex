import Foundation

#if os(Windows)
  import WinSDK
#endif

package enum CodexProcessPipe {
  /// One partial read. The caller owns the handle and serializes reads on it.
  /// Cancellation detaches native observation before returning, so closing is safe.
  package static func readChunk(from handle: FileHandle, maximumBytes: Int = 16_384) async throws
    -> Data?
  {
    precondition(maximumBytes > 0)
    let read = CodexPipeRead(handle: handle, maximumBytes: maximumBytes)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { read.start($0) }
    } onCancel: {
      read.cancel()
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

/// All mutable state and native access belong to queue, including cancellation.
private final class CodexPipeRead: @unchecked Sendable {
  private let queue = DispatchQueue(label: "swift-codex.pipe-read", qos: .utility)
  private let handle: FileHandle
  private let maximumBytes: Int
  private var continuation: CheckedContinuation<Data?, Error>?
  private var source: (any DispatchSourceProtocol)?
  private var cancelled = false
  private var finished = false
  #if !os(Windows)
    private var originalFlags: Int32?
  #endif

  init(handle: FileHandle, maximumBytes: Int) {
    self.handle = handle
    self.maximumBytes = maximumBytes
  }

  func start(_ continuation: CheckedContinuation<Data?, Error>) {
    queue.async {
      self.continuation = continuation
      guard !self.cancelled else {
        self.finish(.failure(CancellationError()))
        return
      }
      #if os(Windows)
        // Foundation's anonymous pipe handles do not support overlapped IO.
        // Peek only on timer events; read no more than the available bytes.
        let source = DispatchSource.makeTimerSource(queue: self.queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(10))
      #else
        let descriptor = self.handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
          self.finish(.failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)))
          return
        }
        self.originalFlags = flags
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: self.queue)
      #endif
      self.source = source
      source.setEventHandler { self.readAvailable() }
      source.resume()
    }
  }

  func cancel() {
    queue.async {
      self.cancelled = true
      if self.continuation != nil { self.finish(.failure(CancellationError())) }
    }
  }

  private func readAvailable() {
    guard !finished else { return }
    var bytes = [UInt8](repeating: 0, count: maximumBytes)
    #if os(Windows)
      var available: DWORD = 0
      guard PeekNamedPipe(handle._handle, nil, 0, nil, &available, nil) else {
        finishWindowsError(GetLastError())
        return
      }
      guard available > 0 else { return }
      var count: DWORD = 0
      let succeeded = bytes.withUnsafeMutableBytes {
        ReadFile(
          handle._handle, $0.baseAddress, min(available, DWORD(clamping: $0.count)), &count, nil)
      }
      guard succeeded else {
        finishWindowsError(GetLastError())
        return
      }
      finish(.success(count == 0 ? nil : Data(bytes.prefix(Int(count)))))
    #else
      let count = bytes.withUnsafeMutableBytes {
        read(handle.fileDescriptor, $0.baseAddress, $0.count)
      }
      if count < 0 {
        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return }
        finish(.failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)))
      } else {
        finish(.success(count == 0 ? nil : Data(bytes.prefix(count))))
      }
    #endif
  }

  #if os(Windows)
    private func finishWindowsError(_ code: DWORD) {
      if code == DWORD(ERROR_BROKEN_PIPE) {
        finish(.success(nil))
      } else {
        finish(.failure(CodexWindowsProcess.error("ReadFile/PeekNamedPipe", code: code)))
      }
    }
  #endif

  private func finish(_ result: Result<Data?, Error>) {
    guard !finished else { return }
    finished = true
    guard let source else {
      resume(result)
      return
    }
    source.setCancelHandler {
      #if !os(Windows)
        if let flags = self.originalFlags {
          _ = fcntl(self.handle.fileDescriptor, F_SETFL, flags)
        }
      #endif
      self.source = nil
      self.resume(result)
    }
    source.cancel()
  }

  private func resume(_ result: Result<Data?, Error>) {
    let pending = continuation
    continuation = nil
    pending?.resume(with: result)
  }
}
