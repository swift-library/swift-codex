import Foundation
import Testing

@testable import CodexMCP

@Suite("CodexMCP transport ownership", .timeLimit(.minutes(1)))
struct CodexMCPTransportOwnershipTests {
  @Test("Send correlation capacity is reclaimed and disconnect settles every observer")
  func boundedSendObservations() async throws {
    let subprocess = CodexMCPManagedSubprocess(standardInput: Pipe(), standardOutput: Pipe()) {}
    let transport = try CodexMCPProcessTransport.make(
      subprocess: subprocess, requestedProtocolVersion: "2025-03-26")
    try await transport.connect()
    var streams: [AsyncThrowingStream<Void, Error>] = []
    for id in 0..<256 {
      streams.append(try await transport.observeRequestSend(.integer(Int64(id))))
    }
    await #expect(throws: CodexMCPError.self) {
      _ = try await transport.observeRequestSend(.integer(256))
    }
    await transport.finishRequestSend(.integer(0))
    streams.append(try await transport.observeRequestSend(.integer(256)))
    async let first: Void = transport.disconnect()
    async let second: Void = transport.disconnect()
    _ = await (first, second)
    var completed = streams[0].makeAsyncIterator()
    #expect(try await completed.next() == nil)
    for stream in streams.dropFirst() {
      var iterator = stream.makeAsyncIterator()
      await #expect(throws: (any Error).self) { _ = try await iterator.next() }
    }
    await #expect(throws: CodexMCPError.self) { try await transport.connect() }
    await subprocess.closeIO()
  }

  @Test("Concurrent disconnect cannot deadlock an observer or deliver its frame after close")
  func disconnectDuringObservation() async throws {
    let input = Pipe()
    let output = Pipe()
    let subprocess = CodexMCPManagedSubprocess(standardInput: input, standardOutput: output) {}
    let transport = try CodexMCPProcessTransport.make(
      subprocess: subprocess, requestedProtocolVersion: "2025-03-26")
    let observation = AsyncPause()
    await transport.setInboundObserver { _ in await observation.enter() }
    try await transport.connect()
    let receive = Task {
      var iterator = await transport.receive().makeAsyncIterator()
      return try await iterator.next()
    }
    try output.fileHandleForWriting.write(contentsOf: Data("{\"ready\":true}\n".utf8))
    await observation.waitUntilEntered()
    async let first: Void = transport.disconnect()
    async let second: Void = transport.disconnect()
    _ = await (first, second)
    await observation.resume()
    #expect(try await receive.value == nil)
    await subprocess.closeIO()
  }

  @Test("A close observer may disconnect the same transport without joining itself")
  func reentrantCloseObserver() async throws {
    let input = Pipe()
    let output = Pipe()
    let subprocess = CodexMCPManagedSubprocess(standardInput: input, standardOutput: output) {}
    let transport = try CodexMCPProcessTransport.make(
      subprocess: subprocess, requestedProtocolVersion: "2025-03-26")
    let recorder = TerminationRecorder()
    await transport.setCloseObserver { [weak transport] _ in
      await transport?.disconnect()
      await recorder.recordTermination()
    }
    try await transport.connect()
    try output.fileHandleForWriting.close()
    var iterator = await transport.receive().makeAsyncIterator()
    await #expect(throws: CodexMCPError.self) { _ = try await iterator.next() }
    await transport.finishCloseNotification()
    #expect(await recorder.terminationCount == 1)
    await subprocess.closeIO()
  }
}
