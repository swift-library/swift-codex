import Foundation
import Testing

@testable import _CodexProcess

@Suite("Bounded process pipe reads", .timeLimit(.minutes(1)))
struct CodexProcessPipeTests {
  @Test("A slow consumer receives bounded chunks in order through EOF")
  func boundedChunksThroughEOF() async throws {
    let pipe = Pipe()
    defer { try? pipe.fileHandleForReading.close() }
    let expected = Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0) })
    let writing = Task {
      defer { try? pipe.fileHandleForWriting.close() }
      try await CodexProcessPipe.write(expected, to: pipe.fileHandleForWriting)
    }
    var received = Data()
    try await CodexProcessPipe.readChunks(from: pipe.fileHandleForReading, capacity: 37) { chunk in
      #expect(!chunk.isEmpty && chunk.count <= 37)
      received.append(chunk)
      await Task.yield()
    }
    try await writing.value
    #expect(received == expected)
  }

  @Test("A consumer error detaches observation before the handle is reused")
  func consumerErrorDetaches() async throws {
    enum ConsumerError: Error { case stopped }
    let pipe = Pipe()
    defer {
      try? pipe.fileHandleForReading.close()
      try? pipe.fileHandleForWriting.close()
    }
    try await CodexProcessPipe.write(Data([1]), to: pipe.fileHandleForWriting)
    await #expect(throws: ConsumerError.self) {
      try await CodexProcessPipe.readChunks(from: pipe.fileHandleForReading) { _ in
        throw ConsumerError.stopped
      }
    }
    try await CodexProcessPipe.write(Data([2]), to: pipe.fileHandleForWriting)
    #expect(try await CodexProcessPipe.readChunk(from: pipe.fileHandleForReading) == Data([2]))
  }

  @Test("Cancellation joins read-ahead while its consumer is suspended")
  func cancelSuspendedConsumer() async throws {
    let pipe = Pipe()
    defer {
      try? pipe.fileHandleForReading.close()
      try? pipe.fileHandleForWriting.close()
    }
    let entered = AsyncStream<Void>.makeStream()
    let reading = Task {
      try await CodexProcessPipe.readChunks(from: pipe.fileHandleForReading, capacity: 1) { _ in
        entered.continuation.yield(())
        try await Task.sleep(for: .seconds(60))
      }
    }
    try await CodexProcessPipe.write(Data([1, 2, 3]), to: pipe.fileHandleForWriting)
    var signal = entered.stream.makeAsyncIterator()
    _ = await signal.next()
    reading.cancel()
    await #expect(throws: CancellationError.self) { try await reading.value }
    entered.continuation.finish()
  }

  @Test("Cancellation after read-ahead EOF still throws")
  func cancelAfterEOF() async throws {
    let pipe = Pipe()
    defer { try? pipe.fileHandleForReading.close() }
    try await CodexProcessPipe.write(Data([1, 2, 3]), to: pipe.fileHandleForWriting)
    try pipe.fileHandleForWriting.close()
    let entered = AsyncStream<Void>.makeStream()
    let suspended = AsyncStream<Void>.makeStream()
    defer {
      entered.continuation.finish()
      suspended.continuation.finish()
    }
    let reading = Task {
      try await CodexProcessPipe.readChunks(from: pipe.fileHandleForReading) { _ in
        entered.continuation.yield(())
        var release = suspended.stream.makeAsyncIterator()
        _ = await release.next()
      }
    }
    var signal = entered.stream.makeAsyncIterator()
    _ = await signal.next()
    reading.cancel()
    await #expect(throws: CancellationError.self) { try await reading.value }
  }

  #if !os(Windows)
    @Test("Read-ahead makes progress while a consumer waits for the producer")
    func readAheadWithoutConsumerScheduling() async throws {
      let process = try await CodexProcess(
        executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
        arguments: [
          "-e",
          """
          $SIG{ALRM} = sub { exit 99 }; alarm 30;
          $|=1; select STDERR; $|=1; select STDOUT;
          print 'r'; read(STDIN, my $go, 1);
          print 'x' x 131072; print STDERR 'drained';
          """,
        ], environment: [:], workingDirectory: nil)
      defer {
        process.cancel()
        try? process.standardInput.close()
        try? process.standardOutput.close()
        try? process.standardError.close()
      }
      var received = Data()
      try await CodexProcessPipe.readChunks(from: process.standardOutput) { chunk in
        let first = received.isEmpty
        received.append(chunk)
        if first {
          try await CodexProcessPipe.write(Data([1]), to: process.standardInput)
          #expect(
            try await CodexProcessPipe.readChunk(from: process.standardError)
              == Data("drained".utf8))
        }
      }
      #expect(try await process.waitForExit().status == 0)
      #expect(received == Data("r".utf8) + Data(repeating: 120, count: 131_072))
    }
  #endif
}
