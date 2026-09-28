import Foundation
import Testing

#if canImport(Darwin)
  import Darwin
  @testable import CodexMCP

  @Suite("CodexMCP native subprocess ownership", .timeLimit(.minutes(1)))
  struct CodexMCPLiveSubprocessTests {
    @Test("Forced process-tree exit joins stderr and closes parent endpoints once")
    func forcedExitJoinsPipes() async throws {
      let subprocess = try await CodexMCPSubprocessLauncher.live.launch(
        .init(
          executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
          arguments: [
            "-e",
            #"$|=1; $SIG{TERM}=sub{}; my $child=fork(); if ($child==0) { sleep 60; exit 0; } print STDERR "token=fixture-secret\n"; print "ready:$child\n"; sleep 60;"#,
          ], currentDirectoryURL: nil, environment: [:]))
      let input = try #require(subprocess.input)
      let output = try #require(subprocess.output)
      let error = try #require(subprocess.error)
      let descriptors = [input.fileDescriptor, output.fileDescriptor, error.fileDescriptor]
      let line = await Task.detached { output.availableData }.value
      #expect(String(decoding: line, as: UTF8.self).hasPrefix("ready:"))
      try await subprocess.terminate()
      async let first: Void = subprocess.closeIO()
      async let second: Void = subprocess.closeIO()
      _ = await (first, second)
      let context = await subprocess.stderrContext()
      #expect(context?.contains("[REDACTED]") == true)
      #expect(context?.contains("fixture-secret") == false)
      for descriptor in descriptors { #expect(fcntl(descriptor, F_GETFD) == -1) }
    }

    @Test("Natural exit and environment overrides complete without retaining stderr writers")
    func naturalExitReleasesStderr() async throws {
      let subprocess = try await CodexMCPSubprocessLauncher.live.launch(
        .init(
          executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
          arguments: [
            "-e",
            #"print $ENV{CODEX_MCP_FIXTURE}; print STDERR "x" x 100000; print STDERR "finished\n";"#,
          ],
          currentDirectoryURL: nil, environment: ["CODEX_MCP_FIXTURE": "native 汉字"]))
      let output = try #require(subprocess.output)
      let data = await Task.detached { output.readDataToEndOfFile() }.value
      #expect(String(decoding: data, as: UTF8.self) == "native 汉字")
      try await subprocess.terminate()
      await subprocess.closeIO()
      let context = await subprocess.stderrContext()
      #expect(context?.hasSuffix("finished\n") == true)
      #expect(context?.utf8.count == 16 * 1_024)
    }
  }
#endif
