import CodexAppServerRuntime
import Foundation
import _CodexProcess

enum CodexAppServerPipeReader {
  static func readLines(
    from handle: FileHandle,
    maximumMessageBytes: Int = CodexAppServerBufferLimits.bytes,
    onLine: (String) async throws -> Void
  ) async throws {
    var codec = CodexAppServerConnectionFoundation.StdioFrameCodec(
      maximumFrameBytes: maximumMessageBytes)
    while !Task.isCancelled {
      guard let chunk = try await CodexProcessPipe.readChunk(from: handle) else {
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
      guard (try? await CodexProcessPipe.readChunk(from: handle)) != nil else { return }
    }
  }

}
