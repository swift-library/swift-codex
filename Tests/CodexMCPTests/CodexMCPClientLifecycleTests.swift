import Foundation
import Testing

@testable import CodexMCP

@Suite("CodexMCP Client Lifecycle", .serialized)
struct CodexMCPClientLifecycleTests {
  @Test("Lifecycle shell starts in the idle state")
  func lifecycleShellStartsIdle() async {
    let client = CodexMCPClient(clientInfo: testMCPClientInfo)

    let state = await client.state

    #expect(state == .idle)
  }

  @Test("Lifecycle shell start transitions idle to running")
  func startTransitionsIdleClientToRunning() async throws {
    let recorder = LaunchRecorder()
    let client = CodexMCPClient(
      clientInfo: testMCPClientInfo,
      subprocessLauncher: .init { configuration in
        await recorder.record(configuration)
        return makeTestSubprocess()
      },
    )

    try await client.start()

    let state = await client.state
    let configurations = await recorder.configurations

    #expect(state == .running)
    #expect(configurations.count == 1)
    #expect(
      configurations.first
        == .init(
          executableURL: URL(fileURLWithPath: "/usr/bin/env"),
          arguments: ["codex", "mcp-server"],
          currentDirectoryURL: nil,
          environment: [:],
        ))
  }

  @Test("Lifecycle shell start is idempotent while already running")
  func startIsIdempotentWhenRunning() async throws {
    let recorder = LaunchRecorder()
    let client = CodexMCPClient(
      clientInfo: testMCPClientInfo,
      subprocessLauncher: .init { configuration in
        await recorder.record(configuration)
        return makeTestSubprocess()
      },
    )

    try await client.start()
    try await client.start()

    let state = await client.state
    let configurations = await recorder.configurations

    #expect(state == .running)
    #expect(configurations.count == 1)
  }

  @Test("Lifecycle shell stop is a non-fatal no-op from idle")
  func stopIsNonFatalNoOpFromIdle() async throws {
    let client = CodexMCPClient(clientInfo: testMCPClientInfo)

    try await client.stop()

    let state = await client.state

    #expect(state == .idle)
  }

  @Test("Lifecycle shell stop transitions running to stopped and remains idempotent")
  func stopTransitionsRunningClientToStopped() async throws {
    let terminationRecorder = TerminationRecorder()
    let client = CodexMCPClient(
      clientInfo: testMCPClientInfo,
      subprocessLauncher: .init { _ in
        makeTestSubprocess {
          await terminationRecorder.recordTermination()
        }
      },
    )

    try await client.start()
    try await client.stop()
    try await client.stop()

    let state = await client.state

    #expect(state == .stopped)
    #expect(await terminationRecorder.terminationCount == 1)
  }

  @Test("Lifecycle shell does not permit restart after stop")
  func startFailsAfterStop() async throws {
    let client = CodexMCPClient(
      clientInfo: testMCPClientInfo,
      subprocessLauncher: .init { _ in
        makeTestSubprocess()
      },
    )

    try await client.start()
    try await client.stop()

    await #expect(throws: CodexMCPError.invalidStateTransition(operation: .start, from: .stopped)) {
      try await client.start()
    }
  }

  @Test("Lifecycle shell exposes starting state during the in-flight start transition")
  func startMakesStartingStateObservable() async throws {
    let pause = AsyncPause()
    let client = CodexMCPClient(
      clientInfo: testMCPClientInfo,
      lifecycleShellHooks: .init(
        onStartTransition: {
          await pause.enter()
        },
      ),
      subprocessLauncher: .init { _ in
        makeTestSubprocess()
      },
    )

    let startTask = Task {
      try await client.start()
    }

    await pause.waitUntilEntered()
    let inFlightState = await client.state
    #expect(inFlightState == .starting)

    await pause.resume()
    try await startTask.value

    let finalState = await client.state
    #expect(finalState == .running)
  }

  @Test("Lifecycle shell waits for an in-flight startup before returning from a second start")
  func concurrentStartWaitsForInFlightStartup() async throws {
    let pause = AsyncPause()
    let secondStartProbe = TaskProbe()
    let client = CodexMCPClient(
      clientInfo: testMCPClientInfo,
      lifecycleShellHooks: .init(
        onStartTransition: {
          await pause.enter()
        },
      ),
      subprocessLauncher: .init { _ in
        makeTestSubprocess()
      },
    )

    let firstStartTask = Task {
      try await client.start()
    }

    await pause.waitUntilEntered()

    let secondStartTask = Task {
      await secondStartProbe.markStarted()
      try await client.start()
      await secondStartProbe.markCompleted()
    }

    await secondStartProbe.waitUntilStarted()
    await Task.yield()

    #expect(await secondStartProbe.didComplete == false)
    #expect(await client.state == .starting)

    await pause.resume()

    try await firstStartTask.value
    try await secondStartTask.value

    #expect(await secondStartProbe.didComplete == true)
    #expect(await client.state == .running)
  }

  @Test("Lifecycle shell exposes stopping state during the in-flight stop transition")
  func stopMakesStoppingStateObservable() async throws {
    let pause = AsyncPause()
    let client = CodexMCPClient(
      clientInfo: testMCPClientInfo,
      lifecycleShellHooks: .init(
        onStopTransition: {
          await pause.enter()
        },
      ),
      subprocessLauncher: .init { _ in
        makeTestSubprocess()
      },
    )

    try await client.start()

    let stopTask = Task {
      try await client.stop()
    }

    await pause.waitUntilEntered()
    let inFlightState = await client.state
    #expect(inFlightState == .stopping)

    await pause.resume()
    try await stopTask.value

    let finalState = await client.state
    #expect(finalState == .stopped)
  }

  @Test("Lifecycle shell stop waits for startup-owned child cleanup before returning from starting")
  func stopDuringStartingWaitsForStartupCleanup() async throws {
    let launchPause = AsyncPause()
    let stopProbe = TaskProbe()
    let terminationRecorder = TerminationRecorder()
    let client = CodexMCPClient(
      clientInfo: testMCPClientInfo,
      subprocessLauncher: .init { _ in
        await launchPause.enter()
        return makeTestSubprocess {
          await terminationRecorder.recordTermination()
        }
      },
    )

    let startTask = Task {
      try await client.start()
    }

    await launchPause.waitUntilEntered()

    let stopTask = Task {
      await stopProbe.markStarted()
      try await client.stop()
      await stopProbe.markCompleted()
    }

    await stopProbe.waitUntilStarted()
    await Task.yield()

    #expect(await stopProbe.didComplete == false)
    #expect(await client.state == .stopping)

    await launchPause.resume()

    await #expect(throws: CodexMCPError.invalidStateTransition(operation: .start, from: .stopped)) {
      try await startTask.value
    }
    try await stopTask.value

    #expect(await terminationRecorder.terminationCount == 1)
    #expect(await stopProbe.didComplete == true)
    #expect(await client.state == .stopped)
  }

  @Test("Lifecycle shell launch options materially participate in process launch behavior")
  func launchOptionsParticipateInProcessLaunchBehavior() async throws {
    let recorder = LaunchRecorder()
    let launchOptions = CodexMCPLaunchOptions(
      executableURL: URL(fileURLWithPath: "/tmp/codex-test-binary"),
      currentDirectoryURL: URL(fileURLWithPath: "/tmp/codex-test-cwd"),
      environment: ["CODEX_TEST_FLAG": "1"],
    )
    let client = CodexMCPClient(
      clientInfo: testMCPClientInfo,
      launchOptions: launchOptions,
      subprocessLauncher: .init { configuration in
        await recorder.record(configuration)
        return makeTestSubprocess()
      },
    )

    try await client.start()

    let configurations = await recorder.configurations
    #expect(
      configurations.first
        == .init(
          executableURL: URL(fileURLWithPath: "/tmp/codex-test-binary"),
          arguments: ["mcp-server"],
          currentDirectoryURL: URL(fileURLWithPath: "/tmp/codex-test-cwd"),
          environment: ["CODEX_TEST_FLAG": "1"],
        ))
  }

  @Test("Lifecycle shell startup handshake sends initialize and notifications/initialized")
  func startupHandshakeSendsInitializeAndInitialized() async throws {
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let transcript = HandshakeTranscript()

    let serverTask = Task {
      let initializeLine = try await readLine(from: stdinPipe.fileHandleForReading.fileDescriptor)
      await transcript.record(initializeLine)
      let initializePayload = try parseJSONObject(from: initializeLine)

      stdoutPipe.fileHandleForWriting.write(
        Data(makeInitializeResponseLine(requestID: initializePayload["id"] ?? 0).utf8)
      )
      stdoutPipe.fileHandleForWriting.write(Data("\n".utf8))

      let initializedLine = try await readLine(from: stdinPipe.fileHandleForReading.fileDescriptor)
      await transcript.record(initializedLine)
    }

    let client = CodexMCPClient(
      clientInfo: testMCPClientInfo,
      subprocessLauncher: .init { _ in
        CodexMCPManagedSubprocess(
          standardInput: stdinPipe,
          standardOutput: stdoutPipe,
          standardError: Pipe(),
        ) {}
      },
    )

    try await client.start()
    try await serverTask.value

    let lines = await transcript.lines
    let initializePayload = try parseJSONObject(from: lines[0])
    let initializeParams = try requiredObject("params", in: initializePayload)
    let initializeCapabilities = try requiredObject("capabilities", in: initializeParams)
    let initializeElicitation = try requiredObject("elicitation", in: initializeCapabilities)

    #expect(initializePayload["jsonrpc"] as? String == "2.0")
    #expect(initializePayload["method"] as? String == "initialize")
    #expect(initializePayload["id"] != nil)
    #expect(initializeParams["protocolVersion"] as? String == "2025-03-26")
    let clientInfo = try requiredObject("clientInfo", in: initializeParams)
    #expect(clientInfo["name"] as? String == "swift-codex-tests")
    #expect(clientInfo["version"] as? String == "0.1.0")
    #expect(try requiredObject("form", in: initializeElicitation).isEmpty)

    let initializedPayload = try parseJSONObject(from: lines[1])
    #expect(initializedPayload["jsonrpc"] as? String == "2.0")
    #expect(initializedPayload["method"] as? String == "notifications/initialized")

    let startupMetadata = await client.startupMetadata
    #expect(startupMetadata == makeStartupMetadata())
  }

}
