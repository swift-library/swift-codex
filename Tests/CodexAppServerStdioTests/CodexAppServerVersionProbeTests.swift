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
    func outputLimit(stderr: Bool) throws {
      let executable = URL(fileURLWithPath: "/usr/bin/perl")
      let configuration = CodexAppServerStdioConfiguration(
        executableURL: executable,
        versionRequirement: .outputContains("codex-probe"),
        versionProbeArguments: [
          "-e", "print \(stderr ? "STDERR " : "")'codex-probe', 'x' x 2000000;",
        ],
        versionProbeTimeoutSeconds: 1)
      #expect(
        throws: CodexAppServerStdioError.executableVersionProbeOutputLimitExceeded(
          executable: executable.path, limitBytes: 65_536)
      ) {
        _ = try configuration.validateBinaryCompatibility()
      }
    }

    @Test(
      "Version probes validate finite bounded deadlines before launch",
      arguments: [0, -1, Double.infinity, Double.nan, 61])
    func invalidDeadline(seconds: Double) throws {
      let configuration = CodexAppServerStdioConfiguration(
        executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
        versionRequirement: .outputContains("codex-probe"), versionProbeTimeoutSeconds: seconds)
      do {
        _ = try configuration.validateBinaryCompatibility()
        Issue.record("Expected invalid probe deadline")
      } catch CodexAppServerStdioError.invalidConfiguration {}
    }

    @Test("Version probes close stdin before waiting for output")
    func inputEOF() throws {
      let configuration = CodexAppServerStdioConfiguration(
        executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
        versionRequirement: .outputContains("codex-probe"),
        versionProbeArguments: [
          "-e",
          "local $/; my $input = <STDIN>; print length($input // '') == 0 ? 'codex-probe' : 'unexpected';",
        ],
        versionProbeTimeoutSeconds: 1)
      let report = try configuration.validateBinaryCompatibility()
      #expect(report.versionProbe?.stdoutText == "codex-probe")
    }

    @Test("Probe timeout joins a process group that ignores graceful termination")
    func timeoutJoinsGroup() throws {
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
          if ($child==0) { alarm 10; sleep 60; exit 0; }
          open(my $file, '>', $ARGV[0]) or die; print $file "$$ $child"; close($file);
          alarm 10; sleep 60;
          """, marker.path,
        ],
        versionProbeTimeoutSeconds: 0.3)
      let started = ContinuousClock.now
      #expect(
        throws: CodexAppServerStdioError.executableVersionProbeTimedOut(
          executable: "/usr/bin/perl", timeoutSeconds: 0.3)
      ) {
        _ = try configuration.validateBinaryCompatibility()
      }
      #expect(started.duration(to: .now) < .seconds(3))
      let members = try String(contentsOf: marker, encoding: .utf8).split(separator: " ")
      #expect(members.count == 2)
      for member in members {
        let pid = try #require(pid_t(member))
        #expect(try hasExited(pid))
      }
    }

    @Test("A completed probe terminates descendants still holding its output pipes")
    func rootExitJoinsGroup() throws {
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
          if ($child==0) { alarm 10; sleep 60; exit 0; }
          open(my $file, '>', $ARGV[0]) or die; print $file $child; close($file);
          print 'codex-probe';
          """, marker.path,
        ],
        versionProbeTimeoutSeconds: 1)
      let started = ContinuousClock.now
      let report = try configuration.validateBinaryCompatibility()
      #expect(report.versionProbe?.stdoutText == "codex-probe")
      #expect(started.duration(to: .now) < .seconds(2))
      let member = try String(contentsOf: marker, encoding: .utf8)
      let pid = try #require(pid_t(member))
      #expect(try hasExited(pid))
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
    func concurrentDrain() throws {
      let configuration = CodexAppServerStdioConfiguration(
        executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
        versionRequirement: .outputContains("codex-probe"),
        versionProbeArguments: [
          "-e", "print 'codex-probe', 'x' x 48000; print STDERR 'y' x 48000;",
        ],
        versionProbeTimeoutSeconds: 1)
      let result = try configuration.validateBinaryCompatibility()
      #expect(
        result.versionProbe?.stdoutText == "codex-probe" + String(repeating: "x", count: 48_000))
      #expect(result.versionProbe?.stderrText == String(repeating: "y", count: 48_000))
      #expect(result.versionProbe?.exitStatus == 0)
    }
  }
#endif
