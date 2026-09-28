import Foundation
import Testing

@testable import _CodexProcess

#if !os(Windows)
  @Suite("Native Codex process ownership", .timeLimit(.minutes(1)))
  struct CodexProcessTests {
    @Test("A configured environment and stdin EOF reach the child")
    func preservesEnvironmentAndEOF() async throws {
      let process = try CodexProcess(
        executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
        arguments: [
          "-e",
          "local $/; my $input = <STDIN>; print $ENV{VALUE}, ':', length($input // ''), ':', scalar(keys %ENV);",
        ],
        environment: ["VALUE": "hello"], workingDirectory: nil)
      try process.standardInput.close()
      let output = try await collect(process.standardOutput)
      let error = try await collect(process.standardError)
      let exit = try await process.waitForExit()
      #expect(String(decoding: output, as: UTF8.self) == "hello:0:1")
      #expect(error.isEmpty)
      #expect(exit.status == 0)
      #expect(!exit.wasSignalled)
    }

    @Test("Cancellation settles every exit waiter")
    func cancellationJoinsExit() async throws {
      let process = try CodexProcess(
        executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
        arguments: ["-e", "$|=1; $SIG{TERM}=sub{exit 0}; print 'ready'; sleep 30;"],
        environment: [:], workingDirectory: nil)
      try process.standardInput.close()
      #expect(
        try await CodexProcessPipe.readChunk(from: process.standardOutput) == Data("ready".utf8))
      async let first = process.waitForExit()
      async let second = process.waitForExit()
      process.cancel()
      let exits = try await [first, second]
      #expect(exits.allSatisfy { $0.status == 0 && !$0.wasSignalled })
      #expect(process.cancellationWasRequested)
      #expect(try await collect(process.standardOutput).isEmpty)
      #expect(try await collect(process.standardError).isEmpty)
    }

    @Test("A missing executable fails before a process is returned")
    func missingExecutableFails() throws {
      #expect(throws: (any Error).self) {
        _ = try CodexProcess(
          executableURL: URL(fileURLWithPath: "/nonexistent/codex-process-fixture"),
          arguments: [], environment: [:], workingDirectory: nil)
      }
    }

    private func collect(_ handle: FileHandle) async throws -> Data {
      defer { try? handle.close() }
      var result = Data()
      while let data = try await CodexProcessPipe.readChunk(from: handle) { result.append(data) }
      return result
    }
  }
#endif
