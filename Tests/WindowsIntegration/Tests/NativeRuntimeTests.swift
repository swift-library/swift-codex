import CodexAppServerStdio
import CodexExec
import Foundation
import Testing

#if os(Windows)
  import WinSDK

  @Suite("Windows native Codex consumers", .timeLimit(.minutes(1)))
  struct NativeRuntimeTests {
    @Test(
      "Invalid Windows environment names fail before child admission",
      arguments: ["duplicate", "equals", "nul", "empty"])
    func invalidEnvironment(kind: String) async throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      var env = environment(mode: "blocked-input", directory: directory)
      switch kind {
      case "duplicate": env["PATH"] = "duplicate"
      case "equals": env["BAD=NAME"] = "fixture"
      case "nul": env["VALUE"] = "bad\u{0}value"
      default: env[""] = "fixture"
      }
      do {
        let transport = try CodexAppServerStdioTransport(
          configuration: .init(
            executableURL: fixture, environment: env))
        await transport.close()
        Issue.record("Invalid environment unexpectedly launched")
      } catch CodexAppServerStdioError.launchFailure(let description) {
        #expect(!description.isEmpty)
      }
      #expect(
        !FileManager.default.fileExists(atPath: directory.appendingPathComponent("root").path))
    }

    @Test("Stdio delivers short Unicode messages while the writer remains open")
    func interactiveLines() async throws {
      try await withTransport(mode: "lines") { transport in
        var incoming = transport.inboundLines.makeAsyncIterator()
        for line in [
          "", "汉字 🐈", "quoted \\\" value", "tail\\", "embedded\u{0}ctrl\u{1A}",
          String(repeating: "汉字🐈", count: 10_000),
        ] {
          try await transport.sendLine(line)
          #expect(try await incoming.next() == line)
        }
      }
    }

    @Test("Explicit environments never fall back to the parent's PATH", arguments: [false, true])
    func explicitEnvironment(setsPath: Bool) async throws {
      let root = try #require(environmentValue("SystemRoot"))
      let transport = try CodexAppServerStdioTransport(
        configuration: .init(
          executableURL: URL(fileURLWithPath: root).appendingPathComponent("System32/cmd.exe"),
          arguments: ["/d", "/c", "echo %PATH%"],
          environment: setsPath ? ["pAtH": "fixture-path"] : [:]))
      do {
        var incoming = transport.inboundLines.makeAsyncIterator()
        #expect(try await incoming.next() == (setsPath ? "fixture-path" : "%PATH%"))
        #expect(try await incoming.next() == nil)
        await transport.close()
      } catch {
        await transport.close()
        throw error
      }
    }

    @Test("Stdio close unblocks a full stdin pipe and joins the root")
    func blockedInputClose() async throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      try await withTransport(mode: "blocked-input", directory: directory) { transport in
        var incoming = transport.inboundLines.makeAsyncIterator()
        #expect(try await incoming.next() == "ready")
        let root = try observe("root", in: directory)
        let sending = Task {
          try await transport.sendLine(String(repeating: "x", count: 2_000_000))
        }
        #expect(try await incoming.next() == "receiving")
        async let first: Void = transport.close()
        async let second: Void = transport.close()
        await first
        await second
        guard case .failure = await sending.result else {
          Issue.record("Incomplete input was accepted")
          return
        }
        #expect(root.hasExited)
        await #expect(throws: CodexAppServerStdioError.closed) {
          try await transport.sendLine("late")
        }
      }
    }

    @Test("Root exit and explicit close join inherited descendants", arguments: [false, true])
    func descendantCleanup(rootExits: Bool) async throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      try await withTransport(mode: rootExits ? "tree-exit" : "tree", directory: directory) {
        transport in
        var incoming = transport.inboundLines.makeAsyncIterator()
        #expect(try await incoming.next() == "ready")
        let members = try ["root", "branch", "leaf"].map { try observe($0, in: directory) }
        if rootExits {
          try Data().write(to: directory.appendingPathComponent("release"))
          #expect(try await incoming.next() == nil)
        }
        await transport.close()
        #expect(members.allSatisfy { $0.hasExited })
      }
    }

    @Test(
      "Exec preserves native arguments, environment, cwd and absent-input EOF",
      arguments: ["", "汉字 🐈", "with spaces", "quoted \" value", "tail \\"])
    func execArguments(prompt: String) async throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let client = CodexExecClient(
        configuration: .init(
          executableURL: fixture,
          environmentOverride: environment(mode: "echo", directory: directory),
          defaultWorkingDirectory: directory))
      let handle = try await client.run(.init(promptInput: .text(prompt)))
      let echo = try await readEcho(handle)
      #expect(echo.arguments.last == prompt)
      #expect(echo.value == "fixture-value")
      #expect(echo.hostOnly.isEmpty)
      #expect(echo.input.isEmpty)
      #expect(normalize(echo.cwd) == normalize(directory.path))
    }

    @Test("Exec delivers complete Unicode stdin before EOF")
    func execStandardInput() async throws {
      let client = CodexExecClient(
        configuration: .init(
          executableURL: fixture, environmentOverride: environment(mode: "echo")))
      let input = String(repeating: "输入🐈", count: 40_000)
      let handle = try await client.run(.init(promptInput: .stdin(input)))
      #expect(try await readEcho(handle).input == input)
    }

    @Test("Exec cancellation joins a blocked stdin writer")
    func execBlockedInput() async throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let client = CodexExecClient(
        configuration: .init(
          executableURL: fixture,
          environmentOverride: environment(mode: "blocked-input", directory: directory)))
      let handle = try await client.run(
        .init(promptInput: .stdin(String(repeating: "x", count: 2_000_000))))
      let waiting = Task { try await handle.waitForTermination() }
      do {
        var lines = handle.stdoutLines.makeAsyncIterator()
        #expect(try await lines.next() == "ready")
        let root = try observe("root", in: directory)
        #expect(try await lines.next() == "receiving")
        waiting.cancel()
        do {
          _ = try await waiting.value
          Issue.record("Expected cancellation")
        } catch CodexExecError.cancelled {}
        #expect(root.hasExited)
      } catch {
        waiting.cancel()
        _ = await waiting.result
        throw error
      }
    }

    @Test("Exec drains both output streams after bounded capture is exhausted")
    func boundedOutput() async throws {
      let client = CodexExecClient(
        configuration: .init(
          executableURL: fixture, environmentOverride: environment(mode: "output"),
          outputLimits: .init(stdoutBytes: 64, stderrBytes: 32)))
      let handle = try await client.run(.init(promptInput: .text("fixture")))
      do {
        _ = try await handle.waitForTermination()
        Issue.record("Expected incomplete capture")
      } catch CodexExecError.outputCaptureLimitExceeded(let observation) {
        #expect(observation.finalMessageText == "kept")
        #expect(observation.stderrText == String(repeating: "y", count: 32))
        #expect(observation.outputCapture.stdoutDroppedBytes == 2_000_006)
        #expect(observation.outputCapture.stderrDroppedBytes == 1_999_968)
      }
    }

    @Test("Exec preserves every native exit-code bit", arguments: [UInt32(3), 0x8000_0005])
    func exitBits(code: UInt32) async throws {
      var env = environment(mode: "exit")
      env["CODEX_FIXTURE_EXIT"] = String(code)
      let client = CodexExecClient(
        configuration: .init(executableURL: fixture, environmentOverride: env))
      let handle = try await client.run(.init(promptInput: .text("fixture")))
      do {
        _ = try await handle.waitForTermination()
        Issue.record("Expected native failure")
      } catch CodexExecError.nonZeroExit(let received, _, _) {
        #expect(received == Int32(bitPattern: code))
      }
    }

    @Test("Exec cancellation joins descendants while another invocation survives")
    func independentCancellation() async throws {
      let firstDirectory = try temporaryDirectory()
      let secondDirectory = try temporaryDirectory()
      defer {
        try? FileManager.default.removeItem(at: firstDirectory)
        try? FileManager.default.removeItem(at: secondDirectory)
      }
      let first = CodexExecClient(
        configuration: .init(
          executableURL: fixture,
          environmentOverride: environment(mode: "tree", directory: firstDirectory)))
      let second = CodexExecClient(
        configuration: .init(
          executableURL: fixture,
          environmentOverride: environment(mode: "tree", directory: secondDirectory)))
      let firstHandle = try await first.run(.init(promptInput: .text("fixture")))
      let firstWait = Task { try await firstHandle.waitForTermination() }
      do {
        let secondHandle = try await second.run(.init(promptInput: .text("fixture")))
        let secondWait = Task { try await secondHandle.waitForTermination() }
        do {
          var firstLines = firstHandle.stdoutLines.makeAsyncIterator()
          var secondLines = secondHandle.stdoutLines.makeAsyncIterator()
          #expect(try await firstLines.next() == "ready")
          #expect(try await secondLines.next() == "ready")
          let firstMembers = try ["root", "branch", "leaf"].map {
            try observe($0, in: firstDirectory)
          }
          let secondMembers = try ["root", "branch", "leaf"].map {
            try observe($0, in: secondDirectory)
          }
          firstWait.cancel()
          do {
            _ = try await firstWait.value
            Issue.record("Expected caller cancellation")
          } catch CodexExecError.cancelled {}
          #expect(firstMembers.allSatisfy { $0.hasExited })
          #expect(secondMembers.allSatisfy { !$0.hasExited })
          secondWait.cancel()
          _ = await secondWait.result
          #expect(secondMembers.allSatisfy { $0.hasExited })
        } catch {
          secondWait.cancel()
          _ = await secondWait.result
          throw error
        }
      } catch {
        firstWait.cancel()
        _ = await firstWait.result
        throw error
      }
    }

    private struct Echo: Decodable {
      let arguments: [String]
      let cwd: String
      let value: String
      let hostOnly: String
      let input: String
    }

    private func readEcho(_ handle: CodexExecProcessHandle) async throws -> Echo {
      var lines: [String] = []
      for try await line in handle.stdoutLines { lines.append(line) }
      let result = try await handle.waitForTermination()
      #expect(result.exitInterpretation == .exited(code: 0))
      #expect(lines.count == 1)
      let line = try #require(lines.first)
      return try JSONDecoder().decode(Echo.self, from: Data(line.utf8))
    }

    private var fixture: URL {
      URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        .appendingPathComponent("CodexProcessFixture.exe")
    }

    private func withTransport(
      mode: String, directory: URL? = nil,
      body: (CodexAppServerStdioTransport) async throws -> Void
    ) async throws {
      let transport = try CodexAppServerStdioTransport(
        configuration: .init(
          executableURL: fixture, environment: environment(mode: mode, directory: directory)))
      do {
        try await body(transport)
        await transport.close()
      } catch {
        await transport.close()
        throw error
      }
    }

    private func environment(mode: String, directory: URL? = nil) -> [String: String] {
      var result = [
        "pAtH": environmentValue("PATH") ?? "", "VALUE": "fixture-value",
        "CODEX_FIXTURE_MODE": mode,
      ]
      if let root = environmentValue("SystemRoot") { result["SystemRoot"] = root }
      if let directory { result["CODEX_FIXTURE_DIRECTORY"] = directory.path }
      return result
    }

    private func environmentValue(_ key: String) -> String? {
      ProcessInfo.processInfo.environment.first {
        $0.key.caseInsensitiveCompare(key) == .orderedSame
      }?.value
    }

    private func temporaryDirectory() throws -> URL {
      let value = FileManager.default.temporaryDirectory.appendingPathComponent(
        "codex native 汉字 \(UUID())")
      try FileManager.default.createDirectory(at: value, withIntermediateDirectories: false)
      return value
    }

    private func normalize(_ path: String) -> String {
      path.replacingOccurrences(of: "/", with: "\\").trimmingCharacters(
        in: CharacterSet(charactersIn: "\\")
      ).lowercased()
    }

    private func observe(_ name: String, in directory: URL) throws -> NativeProcessObservation {
      let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
      let pid = try #require(DWORD(text))
      let handle = try #require(
        OpenProcess(DWORD(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION), false, pid))
      return NativeProcessObservation(handle: handle)
    }
  }

  private final class NativeProcessObservation {
    private let handle: HANDLE
    init(handle: HANDLE) { self.handle = handle }
    deinit { CloseHandle(handle) }
    var hasExited: Bool { WaitForSingleObject(handle, 0) == DWORD(WAIT_OBJECT_0) }
  }
#endif
