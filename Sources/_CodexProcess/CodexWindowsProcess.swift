#if os(Windows)
  import Foundation
  import WinSDK

  final class CodexWindowsProcess: Sendable {
    private let handles: CodexWindowsProcessHandles
    private let job: CodexWindowsJob
    private let completion: Task<CodexProcessExit, Error>

    init(
      executableURL: URL, arguments: [String], environment: [String: String],
      workingDirectory: URL?, input: FileHandle, output: FileHandle, error: FileHandle
    ) throws {
      let job = try CodexWindowsJob()
      let handles = try Self.launch(
        executableURL: executableURL, arguments: arguments, environment: environment,
        workingDirectory: workingDirectory, input: input, output: output, error: error)
      do {
        try job.start(process: handles.process, thread: handles.thread)
      } catch {
        _ = TerminateProcess(handles.process, 1)
        guard WaitForSingleObject(handles.process, 5_000) == DWORD(WAIT_OBJECT_0) else {
          throw CodexProcessFailure(
            description: "Suspended Codex process cleanup could not be confirmed.")
        }
        throw error
      }
      self.handles = handles
      self.job = job
      // Cancellation belongs to the process owner. Caller task cancellation may
      // request termination but cannot cancel or abandon this cleanup task.
      completion = Task.detached {
        while true {
          switch WaitForSingleObject(handles.process, 0) {
          case DWORD(WAIT_OBJECT_0):
            job.stop(.exited)
            try await job.confirmCleanup()
            var code: DWORD = 0
            guard GetExitCodeProcess(handles.process, &code) else {
              throw Self.error("GetExitCodeProcess")
            }
            return CodexProcessExit(status: Int32(bitPattern: code), wasSignalled: false)
          case DWORD(WAIT_TIMEOUT):
            try await Task.sleep(for: .milliseconds(10))
          default:
            let failure = Self.error("WaitForSingleObject")
            job.stop(.failed)
            try await job.confirmCleanup()
            throw failure
          }
        }
      }
    }

    var cancellationWasRequested: Bool { job.cancellationWasRequested }

    func cancel() {
      job.stop(
        WaitForSingleObject(handles.process, 0) == DWORD(WAIT_OBJECT_0) ? .exited : .cancelled)
    }

    func waitForExit() async throws -> CodexProcessExit { try await completion.value }

    private static func launch(
      executableURL: URL, arguments: [String], environment: [String: String],
      workingDirectory: URL?, input: FileHandle, output: FileHandle, error: FileHandle
    ) throws -> CodexWindowsProcessHandles {
      let path = executableURL.path
      let cwd = workingDirectory?.path ?? FileManager.default.currentDirectoryPath
      guard executableURL.isFileURL, workingDirectory?.isFileURL != false,
        !([path, cwd] + arguments).contains(where: { $0.utf16.contains(0) })
      else { throw CodexProcessFailure(description: "Invalid Codex process path or argument.") }
      var command = Array(([path] + arguments).map(quote).joined(separator: " ").utf16) + [0]
      guard command.count <= 32_767 else {
        throw CodexProcessFailure(
          description: "Codex command line exceeds the Windows launch limit.")
      }
      let entries = try environment.sorted { try compareEnvironmentKeys($0.key, $1.key) < 0 }
      var previousKey: String?
      for (key, value) in entries {
        let driveKey = key.utf16.count == 3 && key.hasPrefix("=") && key.hasSuffix(":")
        guard !key.isEmpty, !key.utf16.contains(0), !value.utf16.contains(0),
          !key.contains("=") || driveKey
        else { throw CodexProcessFailure(description: "Invalid Codex process environment entry.") }
        if let previousKey, try compareEnvironmentKeys(previousKey, key) == 0 {
          throw CodexProcessFailure(
            description: "Codex process environment contains duplicate Windows names.")
        }
        previousKey = key
      }
      var environmentBlock =
        Array(entries.map { "\($0.key)=\($0.value)" }.joined(separator: "\0").utf16) + [0, 0]

      var inherited: [HANDLE] = []
      defer { for handle in inherited { CloseHandle(handle) } }
      for handle in [input, output, error] {
        var duplicate: HANDLE?
        guard
          DuplicateHandle(
            GetCurrentProcess(), handle._handle, GetCurrentProcess(), &duplicate, 0, true,
            DWORD(DUPLICATE_SAME_ACCESS)), let duplicate
        else { throw Self.error("DuplicateHandle") }
        inherited.append(duplicate)
      }

      var info = STARTUPINFOEXW()
      info.StartupInfo.cb = DWORD(MemoryLayout<STARTUPINFOEXW>.size)
      info.StartupInfo.dwFlags = DWORD(STARTF_USESTDHANDLES) | DWORD(STARTF_USESHOWWINDOW)
      info.StartupInfo.wShowWindow = WORD(SW_HIDE)
      info.StartupInfo.hStdInput = inherited[0]
      info.StartupInfo.hStdOutput = inherited[1]
      info.StartupInfo.hStdError = inherited[2]
      var attributeBytes: SIZE_T = 0
      _ = InitializeProcThreadAttributeList(nil, 1, 0, &attributeBytes)
      guard attributeBytes > 0 else { throw Self.error("InitializeProcThreadAttributeList") }
      let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(attributeBytes), alignment: 16)
      defer { storage.deallocate() }
      let attributes = LPPROC_THREAD_ATTRIBUTE_LIST(storage)
      guard InitializeProcThreadAttributeList(attributes, 1, 0, &attributeBytes) else {
        throw Self.error("InitializeProcThreadAttributeList")
      }
      defer { DeleteProcThreadAttributeList(attributes) }
      var created = PROCESS_INFORMATION()
      try inherited.withUnsafeMutableBufferPointer { list in
        // Attribute 2 with the input flag is PROC_THREAD_ATTRIBUTE_HANDLE_LIST.
        guard
          UpdateProcThreadAttribute(
            attributes, 0, 0x0002_0002, list.baseAddress,
            SIZE_T(list.count * MemoryLayout<HANDLE>.stride), nil, nil)
        else { throw Self.error("UpdateProcThreadAttribute") }
        info.lpAttributeList = attributes
        let launched = path.withCString(encodedAs: UTF16.self) { executable in
          cwd.withCString(encodedAs: UTF16.self) { directory in
            environmentBlock.withUnsafeMutableBufferPointer { environment in
              withUnsafeMutablePointer(to: &info) { extended in
                extended.withMemoryRebound(to: STARTUPINFOW.self, capacity: 1) { startup in
                  CreateProcessW(
                    executable, &command, nil, nil, true,
                    DWORD(
                      CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT),
                    environment.baseAddress, directory, startup, &created)
                }
              }
            }
          }
        }
        guard launched else { throw Self.error("CreateProcessW") }
      }
      return CodexWindowsProcessHandles(process: created.hProcess!, thread: created.hThread!)
    }

    /// Windows environment names use ordinal, case-insensitive comparison.
    private static func compareEnvironmentKeys(_ left: String, _ right: String) throws -> Int {
      let result = left.withCString(encodedAs: UTF16.self) { left in
        right.withCString(encodedAs: UTF16.self) { right in
          CompareStringOrdinal(left, -1, right, -1, true)
        }
      }
      guard result != 0 else { throw error("CompareStringOrdinal") }
      return Int(result) - Int(CSTR_EQUAL)
    }

    private static func quote(_ argument: String) -> String {
      if !argument.isEmpty, !argument.contains(where: { " \t\r\n\"".contains($0) }) {
        return argument
      }
      var result = "\""
      var slashes = 0
      for character in argument.unicodeScalars {
        if character == "\\" {
          slashes += 1
        } else {
          result += String(repeating: "\\", count: character == "\"" ? slashes * 2 + 1 : slashes)
          result.unicodeScalars.append(character)
          slashes = 0
        }
      }
      return result + String(repeating: "\\", count: slashes * 2) + "\""
    }

    static func error(_ operation: String, code: DWORD = GetLastError()) -> CodexProcessFailure {
      .init(description: "\(operation) failed (Windows error \(code)).")
    }
  }

  /// Immutable kernel tokens remain valid for every borrower until this owner dies.
  /// Native wait/query APIs are thread-safe; no Swift memory is accessed through HANDLE.
  private final class CodexWindowsProcessHandles: @unchecked Sendable {
    let process: HANDLE
    let thread: HANDLE

    init(process: HANDLE, thread: HANDLE) {
      self.process = process
      self.thread = thread
    }

    deinit {
      CloseHandle(thread)
      CloseHandle(process)
    }
  }
#endif
