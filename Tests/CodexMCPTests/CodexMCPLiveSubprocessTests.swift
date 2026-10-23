import Foundation
import Testing
import _CodexProcess

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
      let endpoints = try [input, output, error].map { handle in
        let duplicate = fcntl(handle.fileDescriptor, F_DUPFD_CLOEXEC, 3)
        try #require(duplicate >= 0)
        return (handle.fileDescriptor, FileHandle(fileDescriptor: duplicate, closeOnDealloc: true))
      }
      defer { for (_, retained) in endpoints { try? retained.close() } }
      let line = try #require(await CodexProcessPipe.readChunk(from: output))
      #expect(String(decoding: line, as: UTF8.self).hasPrefix("ready:"))
      try await subprocess.terminate()
      async let first: Void = subprocess.closeIO()
      async let second: Void = subprocess.closeIO()
      _ = await (first, second)
      let context = await subprocess.stderrContext()
      #expect(context?.contains("[REDACTED]") == true)
      #expect(context?.contains("fixture-secret") == false)
      // Retained duplicates prevent pipe identity reuse while parallel fixtures
      // may reuse the original integer descriptors after their endpoints close.
      for (descriptor, retained) in endpoints {
        var original = stat()
        #expect(fstat(retained.fileDescriptor, &original) == 0)
        var current = stat()
        let inspected = fstat(descriptor, &current)
        #expect(inspected == -1 || current.st_ino != original.st_ino)
      }
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
      var data = Data()
      while let chunk = try await CodexProcessPipe.readChunk(from: output) { data.append(chunk) }
      #expect(String(decoding: data, as: UTF8.self) == "native 汉字")
      try await subprocess.terminate()
      await subprocess.closeIO()
      let context = await subprocess.stderrContext()
      #expect(context?.hasSuffix("finished\n") == true)
      #expect(context?.utf8.count == 16 * 1_024)
    }
  }
#endif
