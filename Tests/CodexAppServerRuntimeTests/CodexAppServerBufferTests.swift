import Foundation
import Testing

@testable import CodexAppServerRuntime

@Suite("App Server bounded buffering", .timeLimit(.minutes(1)))
struct CodexAppServerBufferTests {
  typealias Failure = CodexAppServerConnectionFoundation.FoundationError

  @Test("Consumption releases byte and message capacity in FIFO order")
  func capacityRelease() async throws {
    let channel = CodexAppServerAsyncThrowingChannel<Int>(maximumMessages: 2, maximumBytes: 8)
    var iterator = channel.stream.makeAsyncIterator()
    try channel.yield(0, byteCount: 4)
    for next in 1...100 {
      try channel.yield(next, byteCount: 4)
      #expect(try await iterator.next() == next - 1)
    }
    channel.finish()
    #expect(try await iterator.next() == 100)
    #expect(try await iterator.next() == nil)
  }

  @Test("A byte overflow is terminal and exposes no apparently valid backlog")
  func byteOverflow() async throws {
    let channel = CodexAppServerAsyncThrowingChannel<String>(maximumMessages: 4, maximumBytes: 8)
    try channel.yield("汉字", byteCount: 6)
    let failure = Failure.bufferLimitExceeded(maximumMessages: 4, maximumBytes: 8)
    #expect(throws: failure) { try channel.yield("字", byteCount: 3) }
    channel.finish()
    #expect(throws: failure) { try channel.yield("", byteCount: 0) }
    var iterator = channel.stream.makeAsyncIterator()
    await #expect(throws: failure) { try await iterator.next() }
  }

  @Test("Empty messages still consume message capacity")
  func countOverflow() async throws {
    let channel = CodexAppServerAsyncThrowingChannel<String>(maximumMessages: 2, maximumBytes: 8)
    try channel.yield("", byteCount: 0)
    try channel.yield("", byteCount: 0)
    #expect(throws: Failure.bufferLimitExceeded(maximumMessages: 2, maximumBytes: 8)) {
      try channel.yield("", byteCount: 0)
    }
  }

  @Test("An oversized element also fails a waiting consumer")
  func oversizedElement() async throws {
    let channel = CodexAppServerAsyncThrowingChannel<Int>(maximumMessages: 2, maximumBytes: 8)
    let waiting = Task {
      var iterator = channel.stream.makeAsyncIterator()
      return try await iterator.next()
    }
    let failure = Failure.bufferLimitExceeded(maximumMessages: 2, maximumBytes: 8)
    #expect(throws: failure) { try channel.yield(1, byteCount: 9) }
    await #expect(throws: failure) { try await waiting.value }
  }

  @Test("Cancellation does not strand a public stream iterator")
  func cancellation() async throws {
    let channel = CodexAppServerAsyncThrowingChannel<Int>()
    let waiting = Task {
      var iterator = channel.stream.makeAsyncIterator()
      return try await iterator.next()
    }
    waiting.cancel()
    switch await waiting.result {
    case .success(let value): #expect(value == nil)
    case .failure(let error): #expect(error is CancellationError)
    }
    channel.finish()
    #expect(throws: CancellationError.self) { try channel.yield(1, byteCount: 1) }
  }

  @Test("Terminal failure releases queued payload ownership")
  func releasesPayloads() throws {
    final class Payload: Sendable {}
    let channel = CodexAppServerAsyncThrowingChannel<Payload>(maximumMessages: 1, maximumBytes: 1)
    var payload: Payload? = Payload()
    weak var retained = payload
    try channel.yield(payload!, byteCount: 1)
    payload = nil
    #expect(retained != nil)
    #expect(throws: Failure.bufferLimitExceeded(maximumMessages: 1, maximumBytes: 1)) {
      try channel.yield(Payload(), byteCount: 1)
    }
    #expect(retained == nil)
  }

  @Test("Frame bounds count UTF-8 bytes across fragments and CRLF")
  func fragmentedFrameLimit() throws {
    var codec = CodexAppServerConnectionFoundation.StdioFrameCodec(maximumFrameBytes: 8)
    #expect(try codec.appendIncoming(Data("汉".utf8)).isEmpty)
    #expect(try codec.appendIncoming(Data("字x\r\n".utf8)) == ["汉字x"])
    #expect(try codec.appendIncoming(Data(repeating: 0x78, count: 8)).isEmpty)
    #expect(throws: Failure.messageTooLarge(limitBytes: 8)) {
      try codec.appendIncoming(Data([0x78]))
    }
    #expect(!codec.hasPendingPartialLine)
    #expect(try codec.appendIncoming(Data("next\n".utf8)) == ["next"])
    #expect(try codec.encodeOutgoingLine("🐈🐈") == Data("🐈🐈\n".utf8))
    #expect(throws: Failure.messageTooLarge(limitBytes: 8)) {
      try codec.encodeOutgoingLine("🐈🐈x")
    }
  }

  @Test("Many complete frames in one chunk do not share a frame-size budget")
  func multipleFrames() throws {
    var codec = CodexAppServerConnectionFoundation.StdioFrameCodec(maximumFrameBytes: 4)
    #expect(try codec.appendIncoming(Data("1234\nabcd\n\nlast".utf8)) == ["1234", "abcd", ""])
    #expect(try codec.appendIncoming(Data([0x0A])) == ["last"])
    #expect(throws: Failure.messageTooLarge(limitBytes: 4)) {
      try codec.appendIncoming(Data("12345\n".utf8))
    }
  }
}
