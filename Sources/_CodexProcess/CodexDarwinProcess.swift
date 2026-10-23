#if canImport(Darwin)
  import Darwin
  import Foundation

  final class CodexDarwinProcess: @unchecked Sendable {
    private let pid: pid_t
    // The lock covers signals and final reaping. WNOWAIT preserves the root's
    // identity until all group signals are issued; a reused PID is never signalled.
    private let lock = NSLock()
    private var cancelled = false
    // Reaping or a terminal wait failure ends permission to signal the PID.
    private var signalsFinished = false
    private let completion = CodexProcessCompletion()

    init(
      executableURL: URL, arguments: [String], environment: [String: String],
      workingDirectory: URL?, input: FileHandle, output: FileHandle, error: FileHandle
    ) throws {
      pid = try Self.spawn(
        executableURL: executableURL, arguments: arguments, environment: environment,
        workingDirectory: workingDirectory, input: input, output: output, error: error)
      let source = DispatchSource.makeProcessSource(
        identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
      source.setEventHandler { source.cancel() }
      // Retain the zombie PID until the source is detached and all group signals finish.
      source.setCancelHandler { self.observeExit() }
      source.resume()
    }

    var cancellationWasRequested: Bool { lock.withLock { cancelled } }

    var processIdentifier: Int32 { pid }

    func cancel() {
      let requested = lock.withLock {
        guard !signalsFinished, !cancelled else { return false }
        cancelled = true
        _ = kill(-pid, SIGTERM)
        return true
      }
      guard requested else { return }
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(500)) {
        self.lock.withLock {
          guard !self.signalsFinished else { return }
          _ = kill(-self.pid, SIGKILL)
        }
      }
    }

    func waitForExit() async throws -> CodexProcessExit { try await completion.wait() }

    func waitForExit(until deadline: DispatchTime) async throws -> CodexProcessExit? {
      try await completion.wait(until: deadline)
    }

    private func observeExit() {
      do {
        let exited = try Self.pollChild("waitid") {
          var information = siginfo_t()
          let result = waitid(P_PID, id_t(pid), &information, WEXITED | WNOWAIT | WNOHANG)
          return result == 0 ? information.si_pid : -1
        }
        guard exited else {
          DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(10)) {
            self.observeExit()
          }
          return
        }
      } catch {
        lock.withLock { signalsFinished = true }
        completion.finish(.failure(error))
        return
      }
      stopGroup(until: .now() + .seconds(5))
    }

    private func stopGroup(until deadline: DispatchTime) {
      let result: Result<CodexProcessExit, Error>? = lock.withLock {
        let cleanup: Result<Bool, Error> = Result {
          guard try hasLiveGroupMembers() else { return true }
          if kill(-pid, SIGKILL) != 0 {
            let code = errno
            // Darwin skips zombies and may return EPERM for an all-zombie group.
            if code != ESRCH && code != EPERM { throw Self.error("kill process group", code) }
            if try hasLiveGroupMembers() { throw Self.error("kill process group", code) }
          }
          guard DispatchTime.now() < deadline else {
            throw CodexProcessFailure(
              description: "Codex process group cleanup could not be confirmed.")
          }
          return false
        }
        if case .success(false) = cleanup { return nil }
        var status: Int32 = 0
        do {
          guard try Self.pollChild("waitpid", wait: { waitpid(pid, &status, WNOHANG) }) else {
            return nil
          }
        } catch {
          signalsFinished = true
          return .failure(error)
        }
        signalsFinished = true
        if case .failure(let error) = cleanup { return .failure(error) }
        let signal = status & 0x7f
        return .success(
          .init(status: signal == 0 ? (status >> 8) & 0xff : signal, wasSignalled: signal != 0))
      }
      if let result {
        completion.finish(result)
      } else {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(10)) {
          self.stopGroup(until: deadline)
        }
      }
    }

    // A zero PID means the child is not waitable yet, even after NOTE_EXIT.
    // Return to the asynchronous observer instead of spinning or ending ownership.
    static func pollChild(_ operation: String, wait: () -> pid_t) throws -> Bool {
      while true {
        let received = wait()
        if received >= 0 { return received > 0 }
        if errno == EINTR { continue }
        throw error(operation, errno)
      }
    }

    private func hasLiveGroupMembers() throws -> Bool {
      var capacity = 16
      while capacity <= 131_072 {
        var members = [pid_t](repeating: 0, count: capacity)
        let bytes = Int32(capacity * MemoryLayout<pid_t>.stride)
        errno = 0
        let received = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pid), &members, bytes)
        if received == 0 {
          guard errno == 0 || errno == ESRCH else { throw Self.error("proc_listpids", errno) }
          return false
        }
        guard received > 0, received % Int32(MemoryLayout<pid_t>.stride) == 0 else {
          throw Self.error("proc_listpids", errno)
        }
        if received >= bytes {
          capacity *= 2
          continue
        }
        for member in members.prefix(Int(received) / MemoryLayout<pid_t>.stride) where member > 0 {
          var information = proc_bsdinfo()
          let size = Int32(MemoryLayout.size(ofValue: information))
          let inspected = proc_pidinfo(member, PROC_PIDTBSDINFO, 0, &information, size)
          if inspected == 0, errno == ESRCH { continue }
          guard inspected == size else { throw Self.error("proc_pidinfo", errno) }
          if information.pbi_pgid == UInt32(pid), information.pbi_status != UInt32(SZOMB) {
            return true
          }
        }
        return false
      }
      throw CodexProcessFailure(
        description: "Codex process group inventory exceeds its inspection bound.")
    }

    private static func spawn(
      executableURL: URL, arguments: [String], environment: [String: String],
      workingDirectory: URL?, input: FileHandle, output: FileHandle, error: FileHandle
    ) throws -> pid_t {
      let path = executableURL.path
      let cwd = workingDirectory?.path ?? FileManager.default.currentDirectoryPath
      guard executableURL.isFileURL, workingDirectory?.isFileURL != false,
        !([path, cwd] + arguments).contains(where: { $0.utf8.contains(0) }),
        environment.allSatisfy({
          !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.utf8.contains(0)
            && !$0.value.utf8.contains(0)
        })
      else { throw CodexProcessFailure(description: "Invalid Codex process launch inputs.") }

      var attributes: posix_spawnattr_t?
      try check(posix_spawnattr_init(&attributes), "posix_spawnattr_init")
      defer { posix_spawnattr_destroy(&attributes) }
      try check(posix_spawnattr_setpgroup(&attributes, 0), "posix_spawnattr_setpgroup")
      var signals = sigset_t()
      sigfillset(&signals)
      try check(
        posix_spawnattr_setsigdefault(&attributes, &signals), "posix_spawnattr_setsigdefault")
      sigemptyset(&signals)
      try check(posix_spawnattr_setsigmask(&attributes, &signals), "posix_spawnattr_setsigmask")
      try check(
        posix_spawnattr_setflags(
          &attributes,
          Int16(
            POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
              | POSIX_SPAWN_SETSIGMASK)),
        "posix_spawnattr_setflags")

      var actions: posix_spawn_file_actions_t?
      try check(posix_spawn_file_actions_init(&actions), "posix_spawn_file_actions_init")
      defer { posix_spawn_file_actions_destroy(&actions) }
      if #available(macOS 26.0, *) {
        try check(
          posix_spawn_file_actions_addchdir(&actions, cwd), "posix_spawn_file_actions_addchdir")
      } else {
        try check(
          posix_spawn_file_actions_addchdir_np(&actions, cwd),
          "posix_spawn_file_actions_addchdir_np")
      }
      // Private source descriptors cannot alias destinations even when the host
      // starts with a standard descriptor closed. Only these duplicates are inherited.
      var descriptors: [Int32] = []
      defer { for descriptor in descriptors { close(descriptor) } }
      for (index, handle) in [input, output, error].enumerated() {
        let descriptor = fcntl(handle.fileDescriptor, F_DUPFD_CLOEXEC, 3)
        guard descriptor >= 0 else { throw Self.error("fcntl", errno) }
        descriptors.append(descriptor)
        try check(
          posix_spawn_file_actions_adddup2(&actions, descriptor, Int32(index)),
          "posix_spawn_file_actions_adddup2")
      }

      let argumentStrings = [path] + arguments
      let environmentStrings = environment.map { "\($0.key)=\($0.value)" }
      var argv: [UnsafeMutablePointer<CChar>?] = []
      var envp: [UnsafeMutablePointer<CChar>?] = []
      defer {
        for value in argv { free(value) }
        for value in envp { free(value) }
      }
      for value in argumentStrings {
        guard let copy = strdup(value) else { throw Self.error("strdup", ENOMEM) }
        argv.append(copy)
      }
      for value in environmentStrings {
        guard let copy = strdup(value) else { throw Self.error("strdup", ENOMEM) }
        envp.append(copy)
      }
      argv.append(nil)
      envp.append(nil)
      var pid: pid_t = 0
      try check(posix_spawn(&pid, path, &actions, &attributes, &argv, &envp), "posix_spawn")
      return pid
    }

    private static func check(_ code: Int32, _ operation: String) throws {
      if code != 0 { throw error(operation, code) }
    }

    private static func error(_ operation: String, _ code: Int32) -> CodexProcessFailure {
      .init(description: "\(operation) failed (POSIX error \(code)).")
    }
  }
#endif
