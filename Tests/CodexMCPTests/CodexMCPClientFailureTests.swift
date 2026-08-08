import Foundation
import Testing

@testable import CodexMCP

@Suite("CodexMCP Client Failures", .serialized)
struct CodexMCPClientFailureTests {
  @Test(
    "Lifecycle shell startup handshake failure cleans up owned resources and leaves the client failed"
  )
  func startupHandshakeFailureCleansUpOwnedResources() async throws {
    let terminationRecorder = TerminationRecorder()
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()

    let serverTask = Task {
      _ = try await readLine(from: stdinPipe.fileHandleForReading.fileDescriptor)
      stdoutPipe.fileHandleForWriting.closeFile()
    }

    let client = CodexMCPClient(
      clientInfo: testMCPClientInfo,
      subprocessLauncher: .init { _ in
        CodexMCPManagedSubprocess(
          standardInput: stdinPipe,
          standardOutput: stdoutPipe,
          standardError: Pipe(),
        ) {
          await terminationRecorder.recordTermination()
        }
      },
    )

    await #expect(throws: CodexMCPError.startupFailure) {
      try await client.start()
    }

    _ = try await serverTask.value

    let stateAfterFailure = await client.state
    let startupMetadata = await client.startupMetadata

    #expect(stateAfterFailure == .failed)
    #expect(startupMetadata == nil)
    await #expect(throws: CodexMCPError.transportFailure) {
      try await client.writeTransportLine("after-failure")
    }
    #expect(await terminationRecorder.terminationCount == 1)

    try await client.stop()

    let finalState = await client.state
    #expect(finalState == .stopped)
    #expect(await terminationRecorder.terminationCount == 1)
  }

  @Test("Lifecycle shell maps malformed initialize response to protocol failure")
  func malformedInitializeResponseUsesProtocolFailure() async throws {
    let terminationRecorder = TerminationRecorder()
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()

    let serverTask = Task {
      _ = try await readLine(from: stdinPipe.fileHandleForReading.fileDescriptor)
      stdoutPipe.fileHandleForWriting.write(
        Data("{\"jsonrpc\":\"1.0\",\"id\":0,\"result\":{}}\n".utf8)
      )
    }

    let client = CodexMCPClient(
      clientInfo: testMCPClientInfo,
      subprocessLauncher: .init { _ in
        CodexMCPManagedSubprocess(
          standardInput: stdinPipe,
          standardOutput: stdoutPipe,
          standardError: Pipe(),
        ) {
          await terminationRecorder.recordTermination()
        }
      },
    )

    await #expect(throws: CodexMCPError.protocolFailure) {
      try await client.start()
    }

    _ = try await serverTask.value

    let state = await client.state
    let startupMetadata = await client.startupMetadata

    #expect(state == .failed)
    #expect(startupMetadata == nil)
    await #expect(throws: CodexMCPError.transportFailure) {
      try await client.readTransportLine()
    }
    #expect(await terminationRecorder.terminationCount == 1)
  }

  @Test("Lifecycle shell rejects a server protocol version different from the caller request")
  func mismatchedProtocolVersionUsesProtocolFailure() async throws {
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let serverTask = Task {
      let initializeLine = try await readLine(
        from: stdinPipe.fileHandleForReading.fileDescriptor)
      let request = try parseJSONObject(from: initializeLine)
      let response = makeInitializeResponseLine(requestID: request["id"] ?? 0)
        .replacingOccurrences(of: "2025-03-26", with: "2025-06-18")
      stdoutPipe.fileHandleForWriting.write(Data("\(response)\n".utf8))
    }

    let client = CodexMCPClient(
      clientInfo: testMCPClientInfo,
      subprocessLauncher: .init { _ in
        CodexMCPManagedSubprocess(
          standardInput: stdinPipe,
          standardOutput: stdoutPipe,
          standardError: Pipe()
        ) {}
      }
    )

    await #expect(throws: CodexMCPError.protocolFailure) {
      try await client.start()
    }
    try await serverTask.value
  }

  @Test("Lifecycle shell cleans up a launched process when stdio transport setup fails")
  func transportSetupFailureCleansUpLaunchedProcess() async throws {
    let terminationRecorder = TerminationRecorder()
    let client = CodexMCPClient(
      clientInfo: testMCPClientInfo,
      subprocessLauncher: .init { _ in
        CodexMCPManagedSubprocess(
          standardError: Pipe(),
        ) {
          await terminationRecorder.recordTermination()
        }
      },
    )

    await #expect(throws: CodexMCPError.transportFailure) {
      try await client.start()
    }

    let state = await client.state
    #expect(state == .failed)
    #expect(await terminationRecorder.terminationCount == 1)
  }

  @Test("Subprocess stderr is continuously drained, bounded, and redacted")
  func subprocessStderrIsDrainedAndRedacted() async throws {
    let stderr = Pipe()
    let client = CodexMCPClient(
      clientInfo: testMCPClientInfo,
      subprocessLauncher: .init { _ in
        let subprocess = CodexMCPManagedSubprocess(standardError: stderr) {}
        await subprocess.startDrainingStderr()
        stderr.fileHandleForWriting.write(
          Data("startup failed token=top-secret Bearer abc.def.ghi\n".utf8)
        )
        stderr.fileHandleForWriting.closeFile()
        while await subprocess.stderrContext() == nil {
          await Task.yield()
        }
        return subprocess
      }
    )

    do {
      try await client.start()
      Issue.record("Expected stderr-backed transport failure.")
    } catch let CodexMCPError.processFailure(stage, context) {
      #expect(stage == .transport)
      #expect(context.stderr?.contains("top-secret") == false)
      #expect(context.stderr?.contains("abc.def.ghi") == false)
      #expect(context.stderr?.contains("[REDACTED]") == true)
      #expect((context.stderr?.utf8.count ?? 0) <= 16 * 1_024)
    }
  }

  @Test("Lifecycle shell maps launch failure into the CodexMCP error surface")
  func launchFailureUsesCodexMCPErrorSurface() async throws {
    let client = CodexMCPClient(
      clientInfo: testMCPClientInfo,
      subprocessLauncher: .init { _ in
        throw FakeLifecycleError.failure
      },
    )

    await expectProcessFailure(stage: .launch) {
      try await client.start()
    }

    let state = await client.state
    #expect(state == .failed)
  }

  @Test("Lifecycle shell maps stop failure into the CodexMCP error surface")
  func stopFailureUsesCodexMCPErrorSurface() async throws {
    let terminationRecorder = TerminationRecorder()
    let client = CodexMCPClient(
      clientInfo: testMCPClientInfo,
      subprocessLauncher: .init { _ in
        makeTestSubprocess {
          await terminationRecorder.recordTermination()
          throw FakeLifecycleError.failure
        }
      },
    )

    try await client.start()

    await expectProcessFailure(stage: .stop) {
      try await client.stop()
    }

    let state = await client.state
    #expect(state == .failed)
    #expect(await terminationRecorder.terminationCount == 1)
  }

  @Test("Lifecycle shell allows non-fatal cleanup stop from failed state")
  func stopFromFailedStateIsNonFatalCleanup() async throws {
    let terminationRecorder = TerminationRecorder()
    let client = CodexMCPClient(
      clientInfo: testMCPClientInfo,
      subprocessLauncher: .init { _ in
        makeTestSubprocess {
          await terminationRecorder.recordTermination()
          throw FakeLifecycleError.failure
        }
      },
    )

    try await client.start()

    await expectProcessFailure(stage: .stop) {
      try await client.stop()
    }

    try await client.stop()

    let state = await client.state
    #expect(state == .stopped)
    #expect(await terminationRecorder.terminationCount == 2)
  }

}

private func expectProcessFailure(
  stage: CodexMCPError.ProcessFailureStage,
  operation: () async throws -> Void
) async {
  do {
    try await operation()
    Issue.record("Expected process failure at stage \(stage.rawValue).")
  } catch let CodexMCPError.processFailure(actualStage, context) {
    #expect(actualStage == stage)
    #expect(context.message?.isEmpty == false)
  } catch {
    Issue.record("Expected process failure, got \(error).")
  }
}
