import Foundation
import Testing

@testable import _CodexProcess

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

#if !os(Windows)
  @Suite("Native Codex process ownership", .timeLimit(.minutes(1)))
  struct CodexProcessTests {
    @Test("A configured environment and stdin EOF reach the child")
    func preservesEnvironmentAndEOF() async throws {
      let process = try await CodexProcess(
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
      let process = try await CodexProcess(
        executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
        arguments: ["-e", "$|=1; $SIG{TERM}='DEFAULT'; print 'ready'; sleep 30;"],
        environment: [:], workingDirectory: nil)
      try process.standardInput.close()
      #expect(
        try await CodexProcessPipe.readChunk(from: process.standardOutput) == Data("ready".utf8))
      async let first = process.waitForExit()
      async let second = process.waitForExit()
      process.cancel()
      let exits = try await [first, second]
      for exit in exits {
        #expect(exit.status == SIGTERM || exit.status == SIGKILL)
        #expect(exit.status == exits[0].status)
        #expect(exit.wasSignalled)
      }
      #expect(process.cancellationWasRequested)
      #expect(try await collect(process.standardOutput).isEmpty)
      #expect(try await collect(process.standardError).isEmpty)
    }

    @Test("A missing executable fails before a process is returned")
    func missingExecutableFails() async throws {
      await #expect(throws: (any Error).self) {
        _ = try await CodexProcess(
          executableURL: URL(fileURLWithPath: "/nonexistent/codex-process-fixture"),
          arguments: [], environment: [:], workingDirectory: nil)
      }
    }

    @Test("A timed exit waiter leaves other observers and the eventual result intact")
    func exitDeadline() async throws {
      let process = try await CodexProcess(
        executableURL: URL(fileURLWithPath: "/bin/cat"), arguments: [],
        environment: [:], workingDirectory: nil)
      defer { process.cancel() }
      async let eventual = process.waitForExit()
      #expect(try await process.waitForExit(until: .now()) == nil)
      try process.standardInput.close()
      #expect(try await eventual.status == 0)
      #expect(try await process.waitForExit(until: .now())?.status == 0)
      #expect(try await collect(process.standardOutput).isEmpty)
      #expect(try await collect(process.standardError).isEmpty)
    }

    @Test("Cancelling an idle read detaches it while the writer remains open", arguments: 0..<32)
    func cancelledRead(iteration: Int) async throws {
      let pipe = Pipe()
      defer {
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
      }
      let reading = Task { try await CodexProcessPipe.readChunk(from: pipe.fileHandleForReading) }
      if iteration.isMultiple(of: 2) { await Task.yield() }
      reading.cancel()
      await #expect(throws: CancellationError.self) { try await reading.value }
      try await CodexProcessPipe.write(Data("next".utf8), to: pipe.fileHandleForWriting)
      #expect(
        try await CodexProcessPipe.readChunk(from: pipe.fileHandleForReading) == Data("next".utf8))
    }

    private func collect(_ handle: FileHandle) async throws -> Data {
      defer { try? handle.close() }
      var result = Data()
      while let data = try await CodexProcessPipe.readChunk(from: handle) { result.append(data) }
      return result
    }
  }
#endif
