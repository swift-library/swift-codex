import Foundation
import Testing

@testable import CodexAppServerStdio

@Suite("CodexAppServerStdio Binary Discovery")
struct CodexAppServerStdioBinaryDiscoveryTests {
  @Test("Binary discovery resolves explicit executable URL before PATH")
  func binaryDiscoveryResolvesExplicitExecutableURLBeforePATH() throws {
    let temporaryDirectory = try makeTemporaryDirectory(named: "appserver-binary-explicit")
    let explicitExecutable = try writeExecutableScript(
      named: "explicit-codex",
      in: temporaryDirectory,
      contents: "#!/bin/sh\necho explicit\n"
    )
    let pathDirectory = try makeTemporaryDirectory(named: "appserver-binary-path")
    _ = try writeExecutableScript(
      named: "codex",
      in: pathDirectory,
      contents: "#!/bin/sh\necho path\n"
    )

    let configuration = CodexAppServerStdioConfiguration(
      executableURL: explicitExecutable,
      environment: ["PATH": pathDirectory.path]
    )

    let resolution = try configuration.resolveExecutable()
    #expect(resolution.executableURL == explicitExecutable)
    #expect(resolution.source == .explicitURL)
  }

  @Test("Binary discovery resolves codex from configured PATH")
  func binaryDiscoveryResolvesCodexFromConfiguredPATH() throws {
    let temporaryDirectory = try makeTemporaryDirectory(named: "appserver-binary-path")
    let executable = try writeExecutableScript(
      named: "codex",
      in: temporaryDirectory,
      contents: "#!/bin/sh\necho path\n"
    )

    let configuration = CodexAppServerStdioConfiguration(
      environment: ["PATH": temporaryDirectory.path]
    )

    let resolution = try configuration.resolveExecutable()
    #expect(resolution.executableURL == executable)
    #expect(resolution.source == .pathSearch(directory: temporaryDirectory.path))
  }

  @Test("Binary discovery reports missing and non-executable binaries")
  func binaryDiscoveryReportsMissingAndNonExecutableBinaries() throws {
    let temporaryDirectory = try makeTemporaryDirectory(named: "appserver-binary-errors")
    let nonExecutable = temporaryDirectory.appendingPathComponent("codex")
    try "#!/bin/sh\necho no\n".write(to: nonExecutable, atomically: true, encoding: .utf8)

    do {
      _ = try CodexAppServerStdioConfiguration(
        executableURL: temporaryDirectory.appendingPathComponent("missing-codex")
      ).resolveExecutable()
      Issue.record("Expected missing explicit executable to fail.")
    } catch let error as CodexAppServerStdioError {
      guard case .executableNotFound = error else {
        Issue.record("Expected executableNotFound, got \(error).")
        return
      }
    }

    do {
      _ = try CodexAppServerStdioConfiguration(
        executableURL: nonExecutable
      ).resolveExecutable()
      Issue.record("Expected non-executable explicit executable to fail.")
    } catch let error as CodexAppServerStdioError {
      #expect(error == .executableNotExecutable(nonExecutable.path))
    }

    do {
      _ = try CodexAppServerStdioConfiguration(
        environment: ["PATH": temporaryDirectory.path]
      ).resolveExecutable()
      Issue.record("Expected PATH lookup to fail for non-executable candidate.")
    } catch let error as CodexAppServerStdioError {
      guard case .executableNotFound = error else {
        Issue.record("Expected executableNotFound, got \(error).")
        return
      }
    }
  }

  @Test("Binary compatibility accepts configured version output substring")
  func binaryCompatibilityAcceptsConfiguredVersionOutputSubstring() throws {
    let temporaryDirectory = try makeTemporaryDirectory(named: "appserver-binary-version")
    let executable = try writeExecutableScript(
      named: "codex",
      in: temporaryDirectory,
      contents: """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo "codex 1.2.3"
          exit 0
        fi
        exit 64
        """
    )

    let configuration = CodexAppServerStdioConfiguration(
      executableURL: executable,
      versionRequirement: .outputContains("1.2.3")
    )

    let report = try configuration.validateBinaryCompatibility()
    #expect(report.resolution.executableURL == executable)
    #expect(report.versionProbe?.arguments == ["--version"])
    #expect(report.versionProbe?.stdoutText == "codex 1.2.3\n")
    #expect(report.versionProbe?.exitStatus == 0)
  }

  @Test("Binary compatibility reports version mismatch deterministically")
  func binaryCompatibilityReportsVersionMismatchDeterministically() throws {
    let temporaryDirectory = try makeTemporaryDirectory(named: "appserver-binary-version-mismatch")
    let executable = try writeExecutableScript(
      named: "codex",
      in: temporaryDirectory,
      contents: "#!/bin/sh\necho \"codex 1.2.3\"\n"
    )

    let configuration = CodexAppServerStdioConfiguration(
      executableURL: executable,
      versionRequirement: .outputContains("9.9.9")
    )

    do {
      _ = try configuration.validateBinaryCompatibility()
      Issue.record("Expected version mismatch.")
    } catch let error as CodexAppServerStdioError {
      guard case .executableVersionMismatch(let expectedSubstring, let actualOutput) = error else {
        Issue.record("Expected executableVersionMismatch, got \(error).")
        return
      }
      #expect(expectedSubstring == "9.9.9")
      #expect(actualOutput == "codex 1.2.3\n")
    }
  }

  @Test("Binary compatibility reports failed version probe")
  func binaryCompatibilityReportsFailedVersionProbe() throws {
    let temporaryDirectory = try makeTemporaryDirectory(named: "appserver-binary-version-fail")
    let executable = try writeExecutableScript(
      named: "codex",
      in: temporaryDirectory,
      contents: "#!/bin/sh\necho \"version failed\" >&2\nexit 42\n"
    )

    let configuration = CodexAppServerStdioConfiguration(
      executableURL: executable,
      versionRequirement: .outputContains("codex")
    )

    do {
      _ = try configuration.validateBinaryCompatibility()
      Issue.record("Expected failed version probe.")
    } catch let error as CodexAppServerStdioError {
      guard
        case .executableVersionProbeFailed(let executablePath, let exitStatus, let stderr) = error
      else {
        Issue.record("Expected executableVersionProbeFailed, got \(error).")
        return
      }
      #expect(executablePath == executable.path)
      #expect(exitStatus == 42)
      #expect(stderr == "version failed\n")
    }
  }

  @Test("Binary compatibility times out a hanging version probe")
  func binaryCompatibilityTimesOutHangingVersionProbe() throws {
    let temporaryDirectory = try makeTemporaryDirectory(named: "appserver-binary-version-timeout")
    let executable = try writeExecutableScript(
      named: "codex",
      in: temporaryDirectory,
      contents: "#!/bin/sh\nsleep 2\n"
    )

    let configuration = CodexAppServerStdioConfiguration(
      executableURL: executable,
      versionRequirement: .outputContains("codex"),
      versionProbeTimeoutSeconds: 0.1
    )

    do {
      _ = try configuration.validateBinaryCompatibility()
      Issue.record("Expected version probe timeout.")
    } catch let error as CodexAppServerStdioError {
      guard case .executableVersionProbeTimedOut(let executablePath, let timeoutSeconds) = error
      else {
        Issue.record("Expected executableVersionProbeTimedOut, got \(error).")
        return
      }
      #expect(executablePath == executable.path)
      #expect(timeoutSeconds == 0.1)
    }
  }

}
private func makeTemporaryDirectory(named prefix: String) throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

private func writeExecutableScript(
  named name: String,
  in directory: URL,
  contents: String
) throws -> URL {
  let scriptURL = directory.appendingPathComponent(name)
  try contents.write(to: scriptURL, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
  return scriptURL
}
