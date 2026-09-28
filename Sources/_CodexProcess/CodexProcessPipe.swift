import Foundation

#if os(Windows)
  import WinSDK
#endif

package enum CodexProcessPipe {
  /// One partial read, including short replies whose writer remains open.
  package static func readChunk(from handle: FileHandle) async throws -> Data? {
    // Blocking pipe operations must not occupy the cooperative executor.
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

  package static func write(_ data: Data, to handle: FileHandle) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      DispatchQueue.global(qos: .utility).async {
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
