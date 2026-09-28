import Foundation
import Testing

@testable import CodexAppServerStdio

#if !os(Windows)
  import Darwin

  @Suite("CodexAppServerStdio native lifecycle", .timeLimit(.minutes(1)))
  struct CodexAppServerStdioLifecycleTests {
    @Test("Close joins a child whose stdin writer is blocked")
    func closeUnblocksWriter() async throws {
      let transport = try CodexAppServerStdioTransport(
        configuration: .init(
          executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
          arguments: [
            "-e",
            "$|=1; $SIG{TERM}=sub{exit 0}; alarm 10; print \"$$\\n\"; sysread STDIN, $input, 1024; print \"receiving\\n\"; sleep 30;",
          ], environment: [:]))
      var messages = transport.inboundLines.makeAsyncIterator()
      let pidText = try #require(await messages.next())
      let pid = try #require(Int32(pidText))
      let sending = Task { try await transport.sendLine(String(repeating: "x", count: 2_000_000)) }
      #expect(try await messages.next() == "receiving")
      let finishing = Task { try await transport.finishInput() }
      async let firstClose: Void = transport.close()
      async let secondClose: Void = transport.close()
      await firstClose
      await secondClose
      try await finishing.value
      guard case .failure = await sending.result else {
        Issue.record("A child that reads only 1024 bytes cannot accept the complete message.")
        return
      }
      #expect(kill(pid, 0) == -1 && errno == ESRCH)
      #expect(try await messages.next() == nil)
      await #expect(throws: CodexAppServerStdioError.closed) {
        try await transport.sendLine("late")
      }
    }
  }
#endif
