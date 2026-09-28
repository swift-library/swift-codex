import CodexAppServerRuntime
import Foundation
import Testing

@testable import CodexAppServerStdio

@Suite("CodexAppServerStdio pipe streams")
struct CodexAppServerPipeReaderTests {
  @Test("Native pipes preserve line endings, Unicode and embedded NUL bytes")
  func preservesLineContents() async throws {
    let lines = try await collect(Data("first\r\n\n汉字 🐈\u{0}tail\nlast".utf8))
    #expect(lines == ["first", "", "汉字 🐈\u{0}tail", "last"])
  }

  @Test("A line spanning native read chunks retains every UTF-8 byte")
  func preservesChunkedLines() async throws {
    let line = String(repeating: "x", count: 16_383) + "🐈汉字" + String(repeating: "y", count: 40_000)
    let lines = try await collect(Data((line + "\nnext\n").utf8))
    #expect(lines == [line, "next"])
  }

  @Test("Empty EOF does not invent a line")
  func emptyEOF() async throws {
    #expect(try await collect(Data()).isEmpty)
  }

  @Test(
    "Lower input bounds count carriage returns and reject partial lines",
    arguments: ["🐈\r\n", "🐈x"])
  func configuredIncomingBound(wire: String) async throws {
    let pipe = Pipe()
    defer { try? pipe.fileHandleForReading.close() }
    try pipe.fileHandleForWriting.write(contentsOf: Data(wire.utf8))
    try pipe.fileHandleForWriting.close()
    await #expect(
      throws: CodexAppServerConnectionFoundation.FoundationError.messageTooLarge(limitBytes: 4)
    ) {
      try await CodexAppServerPipeReader.readLines(
        from: pipe.fileHandleForReading, maximumMessageBytes: 4
      ) { _ in Issue.record("An oversized frame must not be emitted.") }
    }
  }

  @Test("A short line is delivered while its writer waits for a reply")
  func deliversBeforeWriterEOF() async throws {
    let pipe = Pipe()
    let received = DispatchSemaphore(value: 0)
    defer { try? pipe.fileHandleForReading.close() }
    async let acknowledged: Bool = withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        defer { try? pipe.fileHandleForWriting.close() }
        do {
          try pipe.fileHandleForWriting.write(contentsOf: Data("ping\n".utf8))
          // A failed read must still release EOF so the test can finish.
          let result = received.wait(timeout: .now() + 5) == .success
          continuation.resume(returning: result)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
    var lines: [String] = []
    try await CodexAppServerPipeReader.readLines(from: pipe.fileHandleForReading) { line in
      lines.append(line)
      received.signal()
    }
    #expect(try await acknowledged)
    #expect(lines == ["ping"])
  }

  @Test("Invalid UTF-8 fails for complete and unterminated lines", arguments: [true, false])
  func rejectsInvalidUTF8(terminated: Bool) async throws {
    let pipe = Pipe()
    defer { try? pipe.fileHandleForReading.close() }
    try pipe.fileHandleForWriting.write(contentsOf: Data(terminated ? [0xFF, 0x0A] : [0xFF]))
    try pipe.fileHandleForWriting.close()
    await #expect(throws: CodexAppServerConnectionFoundation.FoundationError.invalidUTF8) {
      try await CodexAppServerPipeReader.readLines(from: pipe.fileHandleForReading) { _ in
        Issue.record("Invalid bytes must not be emitted as a replacement string.")
      }
    }
  }

  @Test("Discarded stderr drains beyond native pipe capacity")
  func drainsDiscardedOutput() async throws {
    let pipe = Pipe()
    defer { try? pipe.fileHandleForReading.close() }
    async let writing = write(
      Data(repeating: 0xFF, count: 2_000_000), to: pipe.fileHandleForWriting)
    await CodexAppServerPipeReader.discard(from: pipe.fileHandleForReading)
    try await writing
  }

  private func collect(_ data: Data) async throws -> [String] {
    let pipe = Pipe()
    defer { try? pipe.fileHandleForReading.close() }
    async let writing = write(data, to: pipe.fileHandleForWriting)
    var lines: [String] = []
    try await CodexAppServerPipeReader.readLines(from: pipe.fileHandleForReading) { line in
      lines.append(line)
    }
    try await writing
    return lines
  }

  private func write(_ data: Data, to handle: FileHandle) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      DispatchQueue.global(qos: .utility).async {
        defer { try? handle.close() }
        do {
          try handle.write(contentsOf: data)
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
}
