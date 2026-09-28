import Foundation

#if canImport(System)
  import System
#else
  @preconcurrency import SystemPackage
#endif
#if os(Windows)
  import WinSDK
  import ucrt
#endif

/// Retains the descriptor bridge for MCP until its transport releases the pipe.
internal final class CodexMCPStdioDescriptors: @unchecked Sendable {
  let input: FileDescriptor
  let output: FileDescriptor

  init(input: FileHandle, output: FileHandle) throws {
    #if os(Windows)
      let reading = try Self.duplicate(input, flags: _O_RDONLY)
      do {
        self.output = FileDescriptor(rawValue: try Self.duplicate(output, flags: _O_WRONLY))
        self.input = FileDescriptor(rawValue: reading)
      } catch {
        _ = _close(reading)
        throw error
      }
    #else
      self.input = FileDescriptor(rawValue: input.fileDescriptor)
      self.output = FileDescriptor(rawValue: output.fileDescriptor)
    #endif
  }

  #if os(Windows)
    deinit {
      _ = _close(input.rawValue)
      _ = _close(output.rawValue)
    }

    private static func duplicate(_ handle: FileHandle, flags: Int32) throws -> Int32 {
      var native: HANDLE?
      guard
        DuplicateHandle(
          GetCurrentProcess(), handle._handle, GetCurrentProcess(), &native, 0, false,
          DWORD(DUPLICATE_SAME_ACCESS)), let native
      else { throw CodexMCPError.transportFailure }
      // _open_osfhandle transfers ownership only on success; MCP borrows this CRT descriptor.
      let descriptor = _open_osfhandle(Int(bitPattern: native), flags | _O_BINARY | _O_NOINHERIT)
      guard descriptor >= 0 else {
        CloseHandle(native)
        throw CodexMCPError.transportFailure
      }
      return descriptor
    }
  #endif
}
