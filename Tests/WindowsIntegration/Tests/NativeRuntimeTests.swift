import CodexAppServerRuntime
import CodexAppServerStdio
import CodexExec
import Foundation
import Testing

#if os(Windows)
  import WinSDK

  @Suite("Windows native Codex consumers", .timeLimit(.minutes(1)))
  struct NativeRuntimeTests {
    @Test("Input EOF preserves final output and late writes do not terminate the child")
    func finishPreservesFinalWork() async throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      try await withTransport(mode: "input-finish", directory: directory) { transport in
        var messages = transport.inboundLines.makeAsyncIterator()
        for line in ["", "汉字 🐈", String(repeating: "x", count: 65_536)] {
          try await transport.sendLine(line)
          #expect(try await messages.next() == line)
        }
        let root = try observe("main", in: directory)
        let finishing = Task { try await transport.finishInput() }
        finishing.cancel()
        try await finishing.value
        try await transport.finishInput()
        #expect(try await messages.next() == "eof")
        await #expect(throws: CodexAppServerStdioError.closed) {
          try await transport.sendLine("late")
        }
        #expect(!root.hasExited)
        try Data().write(to: directory.appendingPathComponent("release"))
        #expect(try await transport.waitForExit() == .exited(23))
        #expect(root.hasExited)
        #expect(try await messages.next() == nil)
      }
    }

    @Test("A lower outgoing frame bound rejects UTF-8 bytes before native writing")
    func configuredOutgoingBound() async throws {
      let transport = try CodexAppServerStdioTransport(
        configuration: .init(
          executableURL: fixture, environment: environment(mode: "lines"), maximumMessageBytes: 4))
      do {
        var messages = transport.inboundLines.makeAsyncIterator()
        await #expect(
          throws: CodexAppServerConnectionFoundation.FoundationError.messageTooLarge(limitBytes: 4)
        ) { try await transport.sendLine("🐈x") }
        try await transport.sendLine("🐈")
        #expect(try await messages.next() == "🐈")
        try await transport.finishInput()
        #expect(try await transport.waitForExit() == .exited(0))
        #expect(try await messages.next() == nil)
        await transport.close()
      } catch {
        await transport.close()
        throw error
      }
    }

    @Test("A lower incoming frame bound terminates and joins the exact child")
    func configuredIncomingBound() async throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let transport = try CodexAppServerStdioTransport(
        configuration: .init(
          executableURL: fixture,
          environment: environment(mode: "oversized-frame", directory: directory),
          maximumMessageBytes: 64))
      do {
        var messages = transport.inboundLines.makeAsyncIterator()
        #expect(try await messages.next() == "ready")
        let root = try observe("root", in: directory)
        try await transport.sendLine("start")
        await #expect(
          throws: CodexAppServerConnectionFoundation.FoundationError.messageTooLarge(limitBytes: 64)
        ) { try await messages.next() }
        _ = try await transport.waitForExit()
        #expect(root.hasExited)
        await transport.close()
      } catch {
        await transport.close()
        throw error
      }
    }

    @Test(
      "Invalid message bounds fail before native launch",
      arguments: [0, -1, 16 * 1_024 * 1_024 + 1, Int.max])
    func invalidFrameBound(limit: Int) throws {
      #expect(
        throws: CodexAppServerStdioError.invalidConfiguration(
          "Maximum message bytes must be positive and no greater than 16 MiB.")
      ) {
        _ = try CodexAppServerStdioTransport(
          configuration: .init(executableName: "", maximumMessageBytes: limit))
      }
    }

    @Test(
      "Stdio exit observation preserves native exit-code bits", arguments: [0, 23, 3_221_225_477])
    func stdioTerminationCode(code: UInt32) async throws {
      var env = environment(mode: "exit")
      env["CODEX_FIXTURE_EXIT"] = String(code)
      let transport = try CodexAppServerStdioTransport(
        configuration: .init(executableURL: fixture, environment: env))
      do {
        #expect(try await transport.waitForExit() == .exited(Int32(bitPattern: code)))
        await transport.close()
      } catch {
        await transport.close()
        throw error
      }
    }

    @Test("Cancelled exit observers retain the shared owner until explicit close")
    func joinedTerminationObservers() async throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      try await withTransport(mode: "lines", directory: directory) { transport in
        let first = Task { try await transport.waitForExit() }
        let second = Task { try await transport.waitForExit() }
        first.cancel()
        do {
          var lines = transport.inboundLines.makeAsyncIterator()
          try await transport.sendLine("still owned")
          #expect(try await lines.next() == "still owned")
          let root = try observe("main", in: directory)
          #expect(UInt32(bitPattern: transport.processIdentifier) == root.processIdentifier)
          #expect(!root.hasExited)
          await transport.close()
          let result = try await first.value
          #expect(try await second.value == result)
          #expect(try await transport.waitForExit() == result)
          #expect(root.hasExited)
        } catch {
          await transport.close()
          _ = await first.result
          _ = await second.result
          throw error
        }
      }
    }

    @Test("Version probes drain both streams and deliver stdin EOF before main launch")
    func boundedVersionProbe() async throws {
      let transport = try CodexAppServerStdioTransport(
        configuration: .init(
          executableURL: fixture, environment: environment(mode: "lines"),
          versionRequirement: .outputContains("codex-probe"),
          versionProbeArguments: ["probe-version"], versionProbeTimeoutSeconds: 2))
      do {
        var lines = transport.inboundLines.makeAsyncIterator()
        try await transport.sendLine("after probe")
        #expect(try await lines.next() == "after probe")
        await transport.close()
      } catch {
        await transport.close()
        throw error
      }
    }

    @Test("Excess probe output fails explicitly without admitting the main process")
    func versionProbeOverflow() throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      #expect(
        throws: CodexAppServerStdioError.executableVersionProbeOutputLimitExceeded(
          executable: fixture.path, limitBytes: 65_536)
      ) {
        _ = try CodexAppServerStdioTransport(
          configuration: .init(
            executableURL: fixture, environment: environment(mode: "lines", directory: directory),
            versionRequirement: .outputContains("codex-probe"),
            versionProbeArguments: ["probe-overflow"], versionProbeTimeoutSeconds: 2))
      }
      #expect(
        !FileManager.default.fileExists(atPath: directory.appendingPathComponent("main").path))
    }

    @Test("Probe timeout joins the exact root and descendant process handles")
    func versionProbeTimeout() async throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let configuration = CodexAppServerStdioConfiguration(
        executableURL: fixture, environment: environment(mode: "lines", directory: directory),
        versionRequirement: .outputContains("codex-probe"),
        versionProbeArguments: ["probe-timeout"], versionProbeTimeoutSeconds: 2)
      let probing = Task.detached { try CodexAppServerStdioTransport(configuration: configuration) }
      do {
        let marker = directory.appendingPathComponent("root").path
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: marker) {
          guard ContinuousClock.now < deadline else { throw FixtureTimeout() }
          try await Task.sleep(for: .milliseconds(10))
        }
        let members = try ["root", "branch", "leaf"].map { try observe($0, in: directory) }
        do {
          let transport = try await probing.value
          await transport.close()
          Issue.record("Expected probe timeout")
        } catch CodexAppServerStdioError.executableVersionProbeTimedOut(let executable, let seconds)
        {
          #expect(executable == fixture.path)
          #expect(seconds == 2)
        }
        #expect(members.allSatisfy { $0.hasExited })
      } catch {
        if case .success(let transport) = await probing.result { await transport.close() }
        throw error
      }
    }

    private struct FixtureTimeout: Error {}

    @Test(
      "Stdio discovers native executables in an explicit Windows PATH",
      arguments: ["codex", "codex.EXE"])
    func stdioDiscovery(name: String) async throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      try FileManager.default.copyItem(
        at: fixture, to: directory.appendingPathComponent("codex.exe"))
      try Data("exit /b 99\r\n".utf8).write(to: directory.appendingPathComponent("codex.cmd"))
      var env = environment(mode: "lines")
      env["pAtH"] = ";\"\(directory.path)\";;" + (env["pAtH"] ?? "")
      env["PATHEXT"] = ".CMD;.EXE"
      let transport = try CodexAppServerStdioTransport(
        configuration: .init(executableName: name, environment: env))
      do {
        var lines = transport.inboundLines.makeAsyncIterator()
        try await transport.sendLine("discovered 汉字")
        #expect(try await lines.next() == "discovered 汉字")
        await transport.close()
      } catch {
        await transport.close()
        throw error
      }
    }

    @Test(
      "Windows discovery rejects path-shaped command names",
      arguments: ["dir\\codex", "C:codex", "codex\u{0}"])
    func invalidExecutableName(name: String) throws {
      do {
        _ = try CodexAppServerStdioTransport(configuration: .init(executableName: name))
        Issue.record("Invalid bare command name was accepted")
      } catch CodexAppServerStdioError.invalidConfiguration {}
    }

    @Test("Windows discovery rejects ambiguous PATH names before spawning")
    func ambiguousPath() throws {
      var env = environment(mode: "lines")
      env["PATH"] = "duplicate"
      do {
        _ = try CodexAppServerStdioTransport(configuration: .init(environment: env))
        Issue.record("Ambiguous PATH was accepted")
      } catch CodexAppServerStdioError.invalidConfiguration {}
    }

    @Test("Exec uses native PATH discovery and replaces case-insensitive API key overrides")
    func execDiscovery() async throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      try FileManager.default.copyItem(
        at: fixture, to: directory.appendingPathComponent("codex.exe"))
      var env = environment(mode: "echo")
      env["pAtH"] = "\(directory.path);" + (env["pAtH"] ?? "")
      env["codex_api_key"] = "fixture-old-key"
      let client = CodexExecClient(
        configuration: .init(environmentOverride: env, apiKey: "fixture-configured-key"))
      let handle = try await client.run(.init(promptInput: .text("discovery")))
      let echo = try await readEcho(handle)
      #expect(echo.arguments.last == "discovery")
      #expect(echo.configuredKeyMatches)
      #expect(echo.hostOnly.isEmpty)
    }

    @Test(
      "Invalid Windows environment names fail before child admission",
      arguments: ["duplicate", "equals", "nul", "empty", "drive"])
    func invalidEnvironment(kind: String) async throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      var env = environment(mode: "blocked-input", directory: directory)
      switch kind {
      case "duplicate": env["PATH"] = "duplicate"
      case "equals": env["BAD=NAME"] = "fixture"
      case "nul": env["VALUE"] = "bad\u{0}value"
      case "drive": env["=1:"] = "fixture"
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

    @Test("An API key override cannot hide a NUL-containing environment name")
    func invalidAPIKeyName() async throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      var env = environment(mode: "blocked-input", directory: directory)
      env["codex_api_key\u{0}suffix"] = "fixture-invalid-key"
      let client = CodexExecClient(
        configuration: .init(
          executableURL: fixture, environmentOverride: env, apiKey: "fixture-configured-key"))
      do {
        let handle = try await client.run(.init(promptInput: .text("invalid environment")))
        let waiting = Task { try await handle.waitForTermination() }
        waiting.cancel()
        _ = await waiting.result
        Issue.record("A malformed environment unexpectedly launched")
      } catch {}
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
      let transport = try CodexAppServerStdioTransport(
        configuration: .init(
          executableURL: fixture.deletingLastPathComponent()
            .appendingPathComponent("CodexEnvironmentFixture.exe"),
          arguments: [], environment: setsPath ? ["pAtH": "fixture-path"] : [:]))
      do {
        var incoming = transport.inboundLines.makeAsyncIterator()
        let received = try await incoming.next()
        #expect(received == (setsPath ? "fixture-path" : "<missing>"))
        #expect(try await incoming.next() == nil)
        await transport.close()
      } catch {
        await transport.close()
        throw error
      }
    }

    @Test("The Windows command processor sees the configured PATH", arguments: [false, true])
    func commandProcessorEnvironment(setsPath: Bool) async throws {
      let root = try #require(environmentValue("SystemRoot"))
      let transport = try CodexAppServerStdioTransport(
        configuration: .init(
          executableURL: URL(fileURLWithPath: root).appendingPathComponent("System32/cmd.exe"),
          arguments: ["/d", "/c", "echo %PATH%"],
          environment: setsPath
            ? ["SystemRoot": root, "pAtH": "fixture-path"] : ["SystemRoot": root],
          versionRequirement: .outputContains(setsPath ? "fixture-path" : "%PATH%"),
          versionProbeArguments: ["/d", "/c", "echo %PATH%"]))
      do {
        var incoming = transport.inboundLines.makeAsyncIterator()
        let received = try await incoming.next()
        #expect(received == (setsPath ? "fixture-path" : "%PATH%"))
        #expect(try await incoming.next() == nil)
        await transport.close()
      } catch {
        await transport.close()
        throw error
      }
    }

    @Test(
      "Incoming overflow joins the native process", arguments: ["oversized-frame", "flood-lines"])
    func incomingOverflow(mode: String) async throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      try await withTransport(mode: mode, directory: directory) { transport in
        var incoming = transport.inboundLines.makeAsyncIterator()
        #expect(try await incoming.next() == "ready")
        let root = try observe("root", in: directory)
        try await transport.sendLine("start")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !root.hasExited && ContinuousClock.now < deadline {
          try await Task.sleep(for: .milliseconds(10))
        }
        let joinedByOverflow = root.hasExited
        if !joinedByOverflow { await transport.close() }
        #expect(joinedByOverflow)
        let failure: CodexAppServerConnectionFoundation.FoundationError =
          mode == "oversized-frame"
          ? .messageTooLarge(limitBytes: 16 * 1_024 * 1_024)
          : .bufferLimitExceeded(maximumMessages: 256, maximumBytes: 16 * 1_024 * 1_024)
        await #expect(throws: failure) { try await incoming.next() }
        _ = try await transport.waitForExit()
        await transport.close()
        #expect(root.hasExited)
      }
    }

    @Test("Native stdin failure joins the exact child handle before returning")
    func stdinFailureClosesProcess() async throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      try await withTransport(mode: "closed-input", directory: directory) { transport in
        var incoming = transport.inboundLines.makeAsyncIterator()
        #expect(try await incoming.next() == "ready")
        let root = try observe("root", in: directory)
        await #expect(throws: (any Error).self) { try await transport.sendLine("request") }
        _ = try await transport.waitForExit()
        let joinedByFailure = root.hasExited
        await transport.close()
        #expect(joinedByFailure)
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
        await #expect(
          throws: CodexAppServerConnectionFoundation.FoundationError.bufferLimitExceeded(
            maximumMessages: 256, maximumBytes: 16 * 1_024 * 1_024)
        ) {
          try await transport.sendLine(String(repeating: "x", count: 15_000_000))
        }
        #expect(!root.hasExited)
        let finishing = Task { try await transport.finishInput() }
        async let first: Void = transport.close()
        async let second: Void = transport.close()
        await first
        await second
        try await finishing.value
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
        #expect(UInt32(bitPattern: transport.processIdentifier) == members[0].processIdentifier)
        if rootExits {
          try Data().write(to: directory.appendingPathComponent("release"))
          #expect(try await incoming.next() == nil)
        }
        await transport.close()
        _ = try await transport.waitForExit()
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
      let configuredKeyMatches: Bool
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
    var processIdentifier: DWORD { GetProcessId(handle) }
    var hasExited: Bool { WaitForSingleObject(handle, 0) == DWORD(WAIT_OBJECT_0) }
  }
#endif
