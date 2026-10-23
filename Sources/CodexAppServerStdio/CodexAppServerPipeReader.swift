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
    try await CodexProcessPipe.readChunks(from: handle) { chunk in
      for line in try codec.appendIncoming(chunk) {
        try await onLine(line)
      }
    }
    if codec.hasPendingPartialLine {
      for line in try codec.appendIncoming(Data([0x0A])) {
        try await onLine(line)
      }
    }
  }

  static func discard(from handle: FileHandle) async {
    try? await CodexProcessPipe.readChunks(from: handle) { _ in }
  }

}
