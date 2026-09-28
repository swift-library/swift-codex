import CodexAppServerRuntime
import Foundation

#if os(Windows)
  import WinSDK
#endif

enum CodexAppServerPipeReader {
  static func readLines(
    from handle: FileHandle,
    onLine: (String) async throws -> Void
  ) async throws {
    var codec = CodexAppServerConnectionFoundation.StdioFrameCodec()
    while !Task.isCancelled {
      guard let chunk = try await readChunk(from: handle) else {
        if codec.hasPendingPartialLine {
          for line in try codec.appendIncoming(Data([0x0A])) {
            try await onLine(line)
          }
        }
        return
      }
      for line in try codec.appendIncoming(chunk) {
        try await onLine(line)
      }
    }
  }

  static func discard(from handle: FileHandle) async {
    while !Task.isCancelled {
      guard (try? await readChunk(from: handle)) != nil else { return }
    }
  }

  private static func readChunk(from handle: FileHandle) async throws -> Data? {
    // A pipe may wait for peer input. Keep its blocking read outside the Swift
    // cooperative executor so the writer and cancellation owner can progress.
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        var bytes = [UInt8](repeating: 0, count: 16_384)
        #if os(Windows)
          var count: DWORD = 0
          let succeeded = bytes.withUnsafeMutableBytes { buffer in
            ReadFile(handle._handle, buffer.baseAddress, DWORD(buffer.count), &count, nil)
          }
          if !succeeded {
            let error = GetLastError()
            if error == ERROR_BROKEN_PIPE {
              continuation.resume(returning: nil)
            } else {
              continuation.resume(throwing: NSError(domain: "NSWin32ErrorDomain", code: Int(error)))
            }
            return
          }
          continuation.resume(returning: count == 0 ? nil : Data(bytes.prefix(Int(count))))
        #else
          while true {
            let count = bytes.withUnsafeMutableBytes { buffer in
              read(handle.fileDescriptor, buffer.baseAddress, buffer.count)
            }
            if count > 0 {
              continuation.resume(returning: Data(bytes.prefix(count)))
              return
            }
            if count == 0 {
              continuation.resume(returning: nil)
              return
            }
            if errno == EINTR { continue }
            continuation.resume(throwing: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
            return
          }
        #endif
      }
    }
  }
}
