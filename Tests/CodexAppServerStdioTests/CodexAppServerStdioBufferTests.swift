import CodexAppServerRuntime
import Foundation
import Testing

@testable import CodexAppServerStdio

#if canImport(Darwin)
  import Darwin

  @Suite("Stdio buffer ownership", .timeLimit(.minutes(1)))
  struct CodexAppServerStdioBufferTests {
    @Test("Exit observers share native identity and cancellation does not terminate the child")
    func joinedTerminationObservers() async throws {
      let transport = try CodexAppServerStdioTransport(
        configuration: .init(
          executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
          arguments: ["-e", "$|=1; alarm 10; print \"$$\\n\"; scalar <STDIN>; exit 23;"],
          environment: [:]))
      let first = Task { try await transport.waitForExit() }
      let second = Task { try await transport.waitForExit() }
      first.cancel()
      do {
        var lines = transport.inboundLines.makeAsyncIterator()
        let text = try #require(await lines.next())
        let pid = try #require(Int32(text))
        #expect(transport.processIdentifier == pid)
        #expect(kill(pid, 0) == 0)
        try await transport.sendLine("finish")
        #expect(try await first.value == .exited(23))
        #expect(try await second.value == .exited(23))
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        await transport.close()
        #expect(try await transport.waitForExit() == .exited(23))
      } catch {
        await transport.close()
        _ = await first.result
        _ = await second.result
        throw error
      }
    }

    @Test(
      "Blocked writes occupy bounded admission until their syscall finishes",
      arguments: [true, false])
    func blockedWriteAdmission(countLimit: Bool) async throws {
      let pipe = Pipe()
      #expect(fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0)
      let capacity = 2_000_000
      let writer = CodexAppServerFileHandleLineWriter(
        handle: pipe.fileHandleForWriting,
        maximumMessages: countLimit ? 1 : 10,
        maximumBytes: capacity)
      let sending = Task { try await writer.write(String(repeating: "x", count: capacity)) }
      let prefix = try await Task.detached {
        try pipe.fileHandleForReading.read(upToCount: 1_024)
      }.value
      #expect(prefix?.count == 1_024)
      await #expect(
        throws: CodexAppServerConnectionFoundation.FoundationError.bufferLimitExceeded(
          maximumMessages: countLimit ? 1 : 10, maximumBytes: capacity)
      ) {
        try await writer.write(countLimit ? "" : "x")
      }
      writer.closeAdmission()
      try pipe.fileHandleForReading.close()
      await writer.close()
      guard case .failure = await sending.result else {
        Issue.record("The unread pipe cannot accept the complete message")
        return
      }
    }

    @Test("A native stdin failure joins a still-running child")
    func stdinFailureClosesProcess() async throws {
      let transport = try CodexAppServerStdioTransport(
        configuration: .init(
          executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
          arguments: ["-e", "$|=1; alarm 10; close STDIN; print \"$$\\n\"; sleep 20;"],
          environment: [:]))
      var incoming = transport.inboundLines.makeAsyncIterator()
      let pidText = try #require(await incoming.next())
      let pid = try #require(Int32(pidText))
      #expect(transport.processIdentifier == pid)
      await #expect(throws: (any Error).self) { try await transport.sendLine("request") }
      _ = try await transport.waitForExit()
      let joinedByFailure = kill(pid, 0) == -1 && errno == ESRCH
      await transport.close()
      #expect(joinedByFailure)
    }

    @Test("Oversized incoming frames terminate and join the owned child")
    func oversizedFrameClosesProcess() async throws {
      let transport = try CodexAppServerStdioTransport(
        configuration: .init(
          executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
          arguments: [
            "-e",
            "$|=1; alarm 10; print \"$$\\n\"; scalar <STDIN>; print 'x' x 17000000; sleep 20;",
          ],
          environment: [:]))
      var incoming = transport.inboundLines.makeAsyncIterator()
      let pidText = try #require(await incoming.next())
      let pid = try #require(Int32(pidText))
      #expect(transport.processIdentifier == pid)
      try await transport.sendLine("start")
      await #expect(
        throws: CodexAppServerConnectionFoundation.FoundationError.messageTooLarge(
          limitBytes: CodexAppServerBufferLimits.bytes)
      ) {
        try await incoming.next()
      }
      await transport.close()
      _ = try await transport.waitForExit()
      #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }
  }
#endif
