import Foundation
import Testing

@testable import CodexExec

@Suite("CodexExec bounded output", .timeLimit(.minutes(1)))
struct CodexExecOutputCaptureTests {
  @Test("Real stdout and stderr drain beyond budgets and expose exact missing byte counts")
  func oversizedPipesDrainWithVisibleMissingOutput() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = try makeExecutableScript(
      in: directory,
      contents: #"""
        #!/usr/bin/perl
        print "kept\n", "x" x 2097152, "\nlast\n";
        print STDERR "y" x 2097152;
        """#)
    let client = CodexExecClient(
      configuration: .init(
        executableURL: executable, environmentOverride: [:],
        outputLimits: .init(stdoutBytes: 64, stderrBytes: 32)))
    let handle = try await client.run(.init(promptInput: .text("unused")))
    var lines: [String] = []
    do {
      for try await line in handle.stdoutLines { lines.append(line) }
      Issue.record("Expected a visible stream capture failure")
    } catch CodexExecError.outputCaptureLimitExceeded(let observation) {
      #expect(observation.outputCapture.stdoutDroppedBytes == 2_097_158)
    }
    #expect(lines == ["kept"])
    do {
      _ = try await handle.waitForTermination()
      Issue.record("Truncated output cannot report complete success")
    } catch CodexExecError.outputCaptureLimitExceeded(let observation) {
      #expect(observation.finalMessageText == "kept")
      #expect(observation.stderrText == String(repeating: "y", count: 32))
      #expect(observation.outputCapture.stdoutDroppedBytes == 2_097_158)
      #expect(observation.outputCapture.stderrDroppedBytes == 2_097_120)
      #expect(!observation.outputCapture.isComplete)
    }
  }

  @Test("A completed JSONL turn cannot hide omitted later output")
  func jsonlCaptureLimitIsNotMalformedOrSuccessful() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = try makeExecutableScript(
      in: directory,
      contents: #"""
        #!/usr/bin/perl
        print '{"type":"thread.started","thread_id":"bounded"}', "\n";
        print '{"type":"turn.completed","usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1}}', "\n";
        print '{"type":"future.event","payload":"', "x" x 2097152, '"}', "\n";
        """#)
    let client = CodexExecClient(
      configuration: .init(
        executableURL: executable, environmentOverride: [:],
        outputLimits: .init(stdoutBytes: 256, stderrBytes: 32)))
    let handle = try await client.run(.init(promptInput: .text("unused"), outputMode: .jsonl))
    // A consumer may wait without draining the stream; its queued bytes are also bounded.
    do {
      _ = try await handle.waitForTermination()
      Issue.record("Expected capture failure despite the completed turn")
    } catch CodexExecError.outputCaptureLimitExceeded(let observation) {
      #expect(observation.resolvedSessionID == "bounded")
      #expect(observation.events.count == 2)
      #expect(observation.outputCapture.stdoutDroppedBytes > 2_097_152)
    }
  }

  @Test("Empty lines cannot bypass the retained line budget")
  func lineCountBudgetBoundsEmptyLines() {
    var parser = CodexExecBoundedLineParser(limits: .init(stdoutBytes: 1_000_000, stdoutLines: 3))
    var lines: [String] = []
    for _ in 0..<10_000 {
      if let line = parser.append(10) { lines.append(line) }
    }
    #expect(parser.finish() == nil)
    #expect(lines == ["", "", ""])
    #expect(parser.droppedBytes == 9_997)
  }

  @Test("Byte limits preserve complete UTF-8 lines, CRLF, and an exact-budget final line")
  func exactBudgetKeepsCompleteLines() {
    let bytes = Array("你好\r\nlast".utf8)
    var parser = CodexExecBoundedLineParser(limits: .init(stdoutBytes: bytes.count))
    var lines: [String] = []
    for byte in bytes {
      if let line = parser.append(byte) { lines.append(line) }
    }
    if let line = parser.finish() { lines.append(line) }
    #expect(lines == ["你好", "last"])
    #expect(parser.droppedBytes == 0)
  }

  @Test("Invalid capture budgets fail before launch")
  func invalidLimitsDoNotLaunch() async throws {
    let launcher = RecordingLauncher()
    let client = CodexExecClient(
      configuration: .init(
        executableURL: URL(fileURLWithPath: "/unused"),
        outputLimits: .init(stderrBytes: -1)), launcher: launcher)
    await #expect(
      throws: CodexExecError.invalidInvocation(
        description: "Output capture budgets must be nonnegative.")
    ) {
      try await client.run(.init(promptInput: .text("unused")))
    }
    #expect(await launcher.recordedLaunches().isEmpty)
  }

  @Test("Cancellation waits for real process cleanup and preserves stderr truncation")
  func cancellationRetainsCaptureMetadata() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = try makeExecutableScript(
      in: directory,
      contents: #"""
        #!/usr/bin/perl
        $| = 1;
        $SIG{TERM} = sub { print STDERR "terminated"; exit 0 };
        print STDERR "y" x 2097152;
        print "ready\n";
        sleep 30;
        print STDERR "natural_exit";
        """#)
    let client = CodexExecClient(
      configuration: .init(
        executableURL: executable, environmentOverride: [:],
        outputLimits: .init(stdoutBytes: 64, stderrBytes: 32)))
    let handle = try await client.run(.init(promptInput: .text("unused")))
    let waiter = Task { try await handle.waitForTermination() }
    var iterator = handle.stdoutLines.makeAsyncIterator()
    #expect(try await iterator.next() == "ready")
    waiter.cancel()
    do {
      _ = try await waiter.value
      Issue.record("Expected caller cancellation")
    } catch CodexExecError.cancelled(let observation) {
      #expect(observation?.finalMessageText == "ready")
      #expect(observation?.stderrText.utf8.count == 32)
      #expect(observation?.outputCapture.stderrDroppedBytes == 2_097_130)
    }
  }
}
