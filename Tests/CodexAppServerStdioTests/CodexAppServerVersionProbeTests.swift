import Foundation
import Testing

@testable import CodexAppServerStdio

#if canImport(Darwin)
  import Darwin
  @Suite("Codex version probe ownership", .timeLimit(.minutes(1)))
  struct CodexAppServerVersionProbeTests {
    @Test(
      "Excess version output reports its capture limit rather than a pipe timeout",
      arguments: [false, true])
    func outputLimit(stderr: Bool) async throws {
      let executable = URL(fileURLWithPath: "/usr/bin/perl")
      let configuration = CodexAppServerStdioConfiguration(
        executableURL: executable,
        versionRequirement: .outputContains("codex-probe"),
        versionProbeArguments: [
          "-e", "print \(stderr ? "STDERR " : "")'codex-probe', 'x' x 2000000;",
        ],
        versionProbeTimeoutSeconds: 1)
      await #expect(
        throws: CodexAppServerStdioError.executableVersionProbeOutputLimitExceeded(
          executable: executable.path, limitBytes: 65_536)
      ) {
        _ = try await configuration.validateBinaryCompatibility()
      }
    }

    @Test(
      "Version probes validate finite bounded deadlines before launch",
      arguments: [0, -1, Double.infinity, Double.nan, 61])
    func invalidDeadline(seconds: Double) async throws {
      let configuration = CodexAppServerStdioConfiguration(
        executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
        versionRequirement: .outputContains("codex-probe"), versionProbeTimeoutSeconds: seconds)
      do {
        _ = try await configuration.validateBinaryCompatibility()
        Issue.record("Expected invalid probe deadline")
      } catch CodexAppServerStdioError.invalidConfiguration {}
    }

    @Test("Version probes close stdin before waiting for output")
    func inputEOF() async throws {
      let configuration = CodexAppServerStdioConfiguration(
        executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
        versionRequirement: .outputContains("codex-probe"),
        versionProbeArguments: [
          "-e",
          "local $/; my $input = <STDIN>; print length($input // '') == 0 ? 'codex-probe' : 'unexpected';",
        ],
        versionProbeTimeoutSeconds: 1)
      let report = try await configuration.validateBinaryCompatibility()
      #expect(report.versionProbe?.stdoutText == "codex-probe")
    }

    @Test("Probe timeout joins a process group that ignores graceful termination")
    func timeoutJoinsGroup() async throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let marker = directory.appendingPathComponent("members")
      let configuration = CodexAppServerStdioConfiguration(
        executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
        versionRequirement: .outputContains("codex-probe"),
        versionProbeArguments: [
          "-e",
          """
          $SIG{TERM}='IGNORE'; my $child=fork(); die unless defined($child);
          if ($child==0) { alarm 300; sleep 300; exit 0; }
          open(my $file, '>', $ARGV[0]) or die; print $file "$$ $child"; close($file);
          alarm 300; sleep 300;
          """, marker.path,
        ],
        versionProbeTimeoutSeconds: 0.3)
      await #expect(
        throws: CodexAppServerStdioError.executableVersionProbeTimedOut(
          executable: "/usr/bin/perl", timeoutSeconds: 0.3)
      ) {
        _ = try await configuration.validateBinaryCompatibility()
      }
      let members = try String(contentsOf: marker, encoding: .utf8).split(separator: " ")
      #expect(members.count == 2)
      for member in members {
        let pid = try #require(pid_t(member))
        #expect(try hasExited(pid))
      }
    }

    @Test("A completed probe terminates descendants still holding its output pipes")
    func rootExitJoinsGroup() async throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let marker = directory.appendingPathComponent("member")
      let configuration = CodexAppServerStdioConfiguration(
        executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
        versionRequirement: .outputContains("codex-probe"),
        versionProbeArguments: [
          "-e",
          """
          my $child=fork(); die unless defined($child);
          if ($child==0) { alarm 300; sleep 300; exit 0; }
          open(my $file, '>', $ARGV[0]) or die; print $file $child; close($file);
          print 'codex-probe';
          """, marker.path,
        ],
        versionProbeTimeoutSeconds: 1)
      let report = try await configuration.validateBinaryCompatibility()
      #expect(report.versionProbe?.stdoutText == "codex-probe")
      let member = try String(contentsOf: marker, encoding: .utf8)
      let pid = try #require(pid_t(member))
      #expect(try hasExited(pid))
    }

    @Test("A version probe allows another Swift task to supply its response")
    func probeYieldsExecutor() async throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let ready = directory.appendingPathComponent("ready")
      let reply = directory.appendingPathComponent("reply")
      let configuration = CodexAppServerStdioConfiguration(
        executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
        versionRequirement: .outputContains("codex-probe"),
        versionProbeArguments: [
          "-e",
          "open(my $f, '>', $ARGV[0]) or die; close($f); until (-e $ARGV[1]) { select undef, undef, undef, 0.01; } print 'codex-probe';",
          ready.path, reply.path,
        ], versionProbeTimeoutSeconds: 1)
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          let report = try await configuration.validateBinaryCompatibility()
          #expect(report.versionProbe?.stdoutText == "codex-probe")
        }
        group.addTask {
          while !FileManager.default.fileExists(atPath: ready.path) {
            try await Task.sleep(for: .milliseconds(10))
          }
          try Data().write(to: reply)
        }
        while try await group.next() != nil {}
      }
    }

    @Test(
      "Cancelling a version probe joins its process before returning",
      arguments: [false, true])
    func cancellationJoinsProbe(ignoresTermination: Bool) async throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let marker = directory.appendingPathComponent("pid")
      let configuration = CodexAppServerStdioConfiguration(
        executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
        versionRequirement: .outputContains("codex-probe"),
        versionProbeArguments: [
          "-e",
          (ignoresTermination ? "$SIG{TERM}='IGNORE'; " : "")
            + #"open(my $f, '>', "$ARGV[0].tmp") or die; print $f $$; close($f); rename "$ARGV[0].tmp", $ARGV[0] or die; sleep 30;"#,
          marker.path,
        ], versionProbeTimeoutSeconds: ignoresTermination ? 0.1 : 5)
      let probing = Task { try await configuration.validateBinaryCompatibility() }
      let cancellation = Task {
        while !FileManager.default.fileExists(atPath: marker.path) {
          try await Task.sleep(for: .milliseconds(10))
        }
        probing.cancel()
      }
      do {
        do {
          _ = try await probing.value
          Issue.record("Expected probe cancellation")
        } catch is CancellationError {}
        cancellation.cancel()
        _ = await cancellation.result
      } catch {
        cancellation.cancel()
        _ = await cancellation.result
        throw error
      }
      let pid = try #require(pid_t(String(contentsOf: marker, encoding: .utf8)))
      #expect(try hasExited(pid))
      var status: Int32 = 0
      #expect(waitpid(pid, &status, WNOHANG) == -1)
      #expect(errno == ECHILD)
    }

    private func temporaryDirectory() throws -> URL {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      return directory
    }

    private func hasExited(_ pid: pid_t) throws -> Bool {
      var information = proc_bsdinfo()
      let size = Int32(MemoryLayout.size(ofValue: information))
      let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &information, size)
      if result == 0, errno == ESRCH { return true }
      guard result == size else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      return information.pbi_status == UInt32(SZOMB)
    }

    @Test("Version probes drain both streams while the process is running")
    func concurrentDrain() async throws {
      let configuration = CodexAppServerStdioConfiguration(
        executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
        versionRequirement: .outputContains("codex-probe"),
        versionProbeArguments: [
          "-e", "print 'codex-probe', 'x' x 48000; print STDERR 'y' x 48000;",
        ],
        versionProbeTimeoutSeconds: 1)
      let result = try await configuration.validateBinaryCompatibility()
      #expect(
        result.versionProbe?.stdoutText == "codex-probe" + String(repeating: "x", count: 48_000))
      #expect(result.versionProbe?.stderrText == String(repeating: "y", count: 48_000))
      #expect(result.versionProbe?.exitStatus == 0)
    }
  }
#endif
