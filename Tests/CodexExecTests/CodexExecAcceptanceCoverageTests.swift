import Foundation
import Testing

@testable import CodexExec

private let requiredAcceptanceScenarios: Set<String> = [
  "simple run",
  "stdin prompt",
  "prompt + piped stdin context",
  "JSONL mode",
  "human-readable/default mode",
  "resume by session id",
  "resume via --last",
  "resume via --all",
  "run images",
  "resume images",
  "resume miss",
  "additional directories",
  "approval mode",
  "search mode",
  "enable feature flags",
  "disable feature flags",
  "model override",
  "OSS mode",
  "profile selection",
  "inline config overrides",
  "sandbox mode",
  "full-auto preset",
  "dangerous bypass",
  "ephemeral mode",
  "color mode",
  "skip git repo check",
  "output-last-message",
  "output-last-message on failure",
  "output-last-message write failure",
  "schema-constrained output",
  "invalid schema file",
  "env override behavior",
  "cwd behavior",
  "non-zero exit / server failure",
  "binary missing / launch failure",
  "unknown event preservation",
  "malformed JSONL failure",
  "partial observation preservation",
  "explicit resume-target-not-found failure",
  "caller cancellation vs upstream interruption",
  "deterministic launch seam without a live codex binary",
]

private let acceptanceTraceability: [String: [String]] = [
  "simple run": [
    "runUsesExplicitRunKind",
    "runInterpretsHumanReadableOutput",
  ],
  "stdin prompt": [
    "runMapsStdinPromptMode",
    "runRejectsEmptyStdinPrompt",
  ],
  "prompt + piped stdin context": [
    "runKeepsPromptAndStdinContextDistinctAtProcessBoundary"
  ],
  "JSONL mode": [
    "runInterpretsJSONLStream"
  ],
  "human-readable/default mode": [
    "runInterpretsHumanReadableOutput"
  ],
  "resume by session id": [
    "resumeUsesExplicitSessionIdentifier",
    "resumeBySessionIdentifierCapturesResolvedSessionID",
  ],
  "resume via --last": [
    "resumeUsesLastSelector"
  ],
  "resume via --all": [
    "resumeMapsDocumentedSurface"
  ],
  "run images": [
    "runMapsDocumentedSurface"
  ],
  "resume images": [
    "resumeMapsDocumentedSurface"
  ],
  "resume miss": [
    "resumeMissReturnsExplicitFailure"
  ],
  "additional directories": [
    "runMapsDocumentedSurface"
  ],
  "approval mode": [
    "runMapsDocumentedSurface"
  ],
  "search mode": [
    "runMapsDocumentedSurface"
  ],
  "enable feature flags": [
    "runMapsDocumentedSurface"
  ],
  "disable feature flags": [
    "runMapsDocumentedSurface"
  ],
  "model override": [
    "runMapsDocumentedSurface"
  ],
  "OSS mode": [
    "runMapsDocumentedSurface"
  ],
  "profile selection": [
    "runMapsDocumentedSurface"
  ],
  "inline config overrides": [
    "runMapsDocumentedSurface",
    "resumeMapsDocumentedSurface",
  ],
  "sandbox mode": [
    "runMapsDocumentedSurface"
  ],
  "full-auto preset": [
    "runMapsDocumentedSurface"
  ],
  "dangerous bypass": [
    "runMapsDocumentedSurface"
  ],
  "ephemeral mode": [
    "runMapsDocumentedSurface"
  ],
  "color mode": [
    "runMapsDocumentedSurface"
  ],
  "skip git repo check": [
    "runMapsDocumentedSurface"
  ],
  "output-last-message": [
    "runVerifiesOutputLastMessageFileOnSuccess"
  ],
  "output-last-message on failure": [
    "failedRunDoesNotOverwriteExistingLastMessageFile"
  ],
  "output-last-message write failure": [
    "runReturnsOutputFileFailureWhenLastMessageFileDoesNotMatch",
    "runReturnsOutputFileFailureWhenLastMessageFileIsMissing",
  ],
  "schema-constrained output": [
    "runMapsDocumentedSurface"
  ],
  "invalid schema file": [
    "runRejectsMissingOutputSchemaFile",
    "runRejectsInvalidSchemaJSON",
  ],
  "env override behavior": [
    "runUsesExplicitEnvironmentOverrideIsolation"
  ],
  "cwd behavior": [
    "runUsesExplicitRunKind",
    "runMapsDocumentedSurface",
    "resumeUsesLastSelector",
  ],
  "non-zero exit / server failure": [
    "runReturnsNonZeroExitFailureWithPartialObservation"
  ],
  "binary missing / launch failure": [
    "runFailsWhenExecutableCannotBeResolved"
  ],
  "unknown event preservation": [
    "runInterpretsJSONLStream"
  ],
  "malformed JSONL failure": [
    "runRejectsMalformedJSONL"
  ],
  "partial observation preservation": [
    "runRejectsJSONLSuccessWithoutCompletedTurn",
    "runReturnsNonZeroExitFailureWithPartialObservation",
    "resumeMissReturnsExplicitFailure",
    "runReturnsInterruptedForInterruptedExecution",
    "runReturnsOutputFileFailureWhenLastMessageFileDoesNotMatch",
  ],
  "explicit resume-target-not-found failure": [
    "resumeMissReturnsExplicitFailure"
  ],
  "caller cancellation vs upstream interruption": [
    "runReturnsCancelledWhenLaunchIsCancelled",
    "runCancelsRealChildProcess",
    "runReturnsCancelledWithPartialObservationFromCapturedOutput",
    "runReturnsInterruptedForInterruptedExecution",
    "runTreatsTerminationSignalAsInterruptedNotCancelled",
  ],
  "deterministic launch seam without a live codex binary": [
    "acceptanceCoverageUsesInjectedLauncherWithoutLiveBinary"
  ],
]

@Suite("CodexExec Acceptance Coverage")
struct CodexExecAcceptanceCoverageTests {
  @Test("Acceptance coverage keeps required architecture scenarios explicitly traceable")
  func acceptanceCoverageKeepsRequiredScenariosTraceable() {
    #expect(Set(acceptanceTraceability.keys) == requiredAcceptanceScenarios)
    #expect(acceptanceTraceability.values.allSatisfy { !$0.isEmpty })
  }

  @Test("Injected launch seam keeps contract tests independent from a live codex binary")
  func acceptanceCoverageUsesInjectedLauncherWithoutLiveBinary() async throws {
    let launcher = RecordingLauncher(
      output: CodexExecProcessOutput(
        exitStatus: 0,
        terminationSignal: nil,
        standardOutput: Data("deterministic reply".utf8),
        standardError: Data()
      )
    )
    let executableURL = URL(fileURLWithPath: "/path/to/nonexistent/codex")
    let client = CodexExecClient(
      configuration: CodexExecLaunchConfiguration(
        executableURL: executableURL
      ),
      launcher: launcher
    )

    let handle = try await client.run(CodexExecRunRequest(promptInput: .text("hello")))
    let launch = try #require(await launcher.recordedLaunches().first)
    let lines = try await collectLines(from: handle.stdoutLines)
    let termination = try await handle.waitForTermination()

    #expect(launch.executableURL == executableURL)
    #expect(lines == ["deterministic reply"])
    #expect(termination.operation == .run)
  }

  @Test("System launcher drains large stdout and stderr without blocking on exit")
  func systemLauncherDrainsLargeOutputWithoutBlocking() async throws {
    let launcher = CodexExecSystemLauncher()
    let chunkSize = 65_536
    let chunkCount = 40
    let expectedBytes = chunkSize * chunkCount
    let perlScript = """
      $SIG{ALRM} = sub { exit 99 };
      alarm 2;
      my $chunk = "x" x \(chunkSize);
      for (1..\(chunkCount)) {
        print STDOUT $chunk;
        print STDERR $chunk;
      }
      exit 0;
      """
    let launch = CodexExecPreparedLaunch(
      kind: .run(CodexExecRunRequest(promptInput: .text("unused"))),
      executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
      arguments: ["-e", perlScript],
      environment: ProcessInfo.processInfo.environment,
      workingDirectory: nil,
      standardInput: nil
    )

    let launched = try await launcher.launch(launch)
    let output = try await launched.waitForOutput()

    #expect(output.exitStatus == 0)
    #expect(output.terminationSignal == nil)
    #expect(output.standardOutput.count == expectedBytes)
    #expect(output.standardError.count == expectedBytes)
  }

  @Test("System launcher avoids deadlock when large stdin and large output overlap")
  func systemLauncherHandlesLargeInputAndOutputWithoutDeadlock() async throws {
    let launcher = CodexExecSystemLauncher()
    let chunkSize = 65_536
    let chunkCount = 20
    let expectedBytes = chunkSize * chunkCount
    let perlScript = """
      $SIG{ALRM} = sub { exit 99 };
      alarm 2;
      my $chunk = "y" x \(chunkSize);
      for (1..\(chunkCount)) {
        print STDOUT $chunk;
        print STDERR $chunk;
      }
      my $input = "";
      while (read(STDIN, my $buffer, 65536)) {
        $input .= $buffer;
      }
      exit(length($input) == \(expectedBytes) ? 0 : 98);
      """
    let launch = CodexExecPreparedLaunch(
      kind: .run(CodexExecRunRequest(promptInput: .stdin("unused"))),
      executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
      arguments: ["-e", perlScript],
      environment: ProcessInfo.processInfo.environment,
      workingDirectory: nil,
      standardInput: Data(repeating: 122, count: expectedBytes)
    )

    let launched = try await launcher.launch(launch)
    let output = try await launched.waitForOutput()

    #expect(output.exitStatus == 0)
    #expect(output.terminationSignal == nil)
    #expect(output.standardOutput.count == expectedBytes)
    #expect(output.standardError.count == expectedBytes)
  }

  @Test("Run keeps argv prompt and piped stdin context distinct at the process boundary")
  func runKeepsPromptAndStdinContextDistinctAtProcessBoundary() async throws {
    let launcher = RecordingLauncher()
    let client = CodexExecClient(
      configuration: CodexExecLaunchConfiguration(
        executableURL: URL(fileURLWithPath: "/tmp/codex")
      ),
      launcher: launcher
    )

    _ = try await client.run(
      CodexExecRunRequest(
        promptInput: .textWithStdinContext(prompt: "summarize this", stdin: "raw context")
      )
    )

    let launch = try #require(await launcher.recordedLaunches().first)
    #expect(launch.arguments == ["exec", "summarize this"])
    #expect(launch.standardInput == Data("raw context".utf8))
  }

  @Test("Empty stdin prompt fails deterministically before launch")
  func runRejectsEmptyStdinPrompt() async throws {
    let launcher = RecordingLauncher()
    let client = CodexExecClient(
      configuration: CodexExecLaunchConfiguration(
        executableURL: URL(fileURLWithPath: "/tmp/codex")
      ),
      launcher: launcher
    )

    do {
      _ = try await client.run(CodexExecRunRequest(promptInput: .stdin("")))
      Issue.record("Expected an invalid invocation failure.")
    } catch let error as CodexExecError {
      switch error {
      case .invalidInvocation(let description):
        #expect(description.contains("Prompt stdin cannot be empty"))
      default:
        Issue.record("Expected an invalid invocation failure.")
      }
    }

    #expect(await launcher.recordedLaunches().isEmpty)
  }

  @Test("Resume via --last stays explicit and deterministic")
  func resumeUsesLastSelector() async throws {
    let launcher = RecordingLauncher()
    let workingDirectory = URL(fileURLWithPath: "/tmp/resume-last")
    let client = CodexExecClient(
      configuration: CodexExecLaunchConfiguration(
        executableURL: URL(fileURLWithPath: "/tmp/codex"),
        defaultWorkingDirectory: workingDirectory
      ),
      launcher: launcher
    )
    let request = CodexExecResumeRequest(
      selector: .last,
      promptInput: .text("follow up")
    )

    let handle = try await client.resume(request)
    let launch = try #require(await launcher.recordedLaunches().first)
    let termination = try await handle.waitForTermination()

    #expect(
      launch.arguments == ["exec", "--cd", workingDirectory.path, "resume", "--last", "follow up"])
    #expect(termination.operation == .resume)
    #expect(termination.effectiveWorkingDirectory == workingDirectory)
  }

  @Test("Resume by session id can capture the resolved session identifier from JSONL output")
  func resumeBySessionIdentifierCapturesResolvedSessionID() async throws {
    let jsonl = [
      #"{"type":"thread.started","thread_id":"session-123"}"#,
      #"{"type":"item.completed","item":{"id":"item-1","type":"agent_message","text":"follow-up answer"}}"#,
      #"{"type":"turn.completed","usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1}}"#,
    ].joined(separator: "\n")
    let launcher = RecordingLauncher(
      output: CodexExecProcessOutput(
        exitStatus: 0,
        terminationSignal: nil,
        standardOutput: Data(jsonl.utf8),
        standardError: Data()
      )
    )
    let client = CodexExecClient(
      configuration: CodexExecLaunchConfiguration(
        executableURL: URL(fileURLWithPath: "/tmp/codex")
      ),
      launcher: launcher
    )

    let observed = try await observeJSONLHandle(
      try await client.resume(
        CodexExecResumeRequest(
          selector: .sessionID("session-123"),
          promptInput: .text("follow up"),
          outputMode: .jsonl
        )
      ))

    #expect(observed.termination.operation == .resume)
    #expect(observed.resolvedSessionID == "session-123")
    #expect(observed.finalMessageText == "follow-up answer")
  }

  @Test("Environment override remains isolated at the process boundary")
  func runUsesExplicitEnvironmentOverrideIsolation() async throws {
    let launcher = RecordingLauncher()
    let client = CodexExecClient(
      configuration: CodexExecLaunchConfiguration(
        executableURL: URL(fileURLWithPath: "/tmp/codex"),
        environmentOverride: [
          "PATH": "/usr/bin",
          "CUSTOM": "1",
        ],
        apiKey: "api-key"
      ),
      launcher: launcher
    )

    _ = try await client.run(CodexExecRunRequest(promptInput: .text("hello")))
    let launch = try #require(await launcher.recordedLaunches().first)

    #expect(
      launch.environment == [
        "PATH": "/usr/bin",
        "CUSTOM": "1",
        "CODEX_API_KEY": "api-key",
      ]
    )
  }

  @Test("Executable resolution failure is deterministic and does not invoke the launcher")
  func runFailsWhenExecutableCannotBeResolved() async throws {
    let launcher = RecordingLauncher()
    let client = CodexExecClient(
      configuration: CodexExecLaunchConfiguration(
        environmentOverride: ["PATH": ""]
      ),
      launcher: launcher
    )

    do {
      _ = try await client.run(CodexExecRunRequest(promptInput: .text("hello")))
      Issue.record("Expected a launch failure.")
    } catch let error as CodexExecError {
      switch error {
      case .launchFailure(let description):
        #expect(description.contains("Unable to resolve the `codex` executable"))
      default:
        Issue.record("Expected a launch failure.")
      }
    }

    #expect(await launcher.recordedLaunches().isEmpty)
  }

  @Test("Failed runs do not overwrite an existing output-last-message file")
  func failedRunDoesNotOverwriteExistingLastMessageFile() async throws {
    let temporaryDirectory = try makeTemporaryDirectory(named: "codexexec-last-message-preserve")
    let outputFile = temporaryDirectory.appendingPathComponent("last.txt")
    try "keep me".write(to: outputFile, atomically: true, encoding: .utf8)

    let launcher = RecordingLauncher(
      output: CodexExecProcessOutput(
        exitStatus: 1,
        terminationSignal: nil,
        standardOutput: Data("partial reply".utf8),
        standardError: Data("synthetic server error".utf8)
      )
    )
    let client = CodexExecClient(
      configuration: CodexExecLaunchConfiguration(
        executableURL: temporaryDirectory.appendingPathComponent("codex")
      ),
      launcher: launcher
    )

    do {
      let handle = try await client.run(
        CodexExecRunRequest(
          promptInput: .text("hello"),
          outputLastMessageFile: outputFile
        )
      )
      _ = try await handle.waitForTermination()
      Issue.record("Expected a non-zero exit failure.")
    } catch let error as CodexExecError {
      switch error {
      case .nonZeroExit(let code, let stderr, let partialObservation):
        #expect(code == 1)
        #expect(stderr == "synthetic server error")
        #expect(partialObservation?.finalMessageText == "partial reply")
      default:
        Issue.record("Expected a non-zero exit failure.")
      }
    }

    #expect(try String(contentsOf: outputFile, encoding: .utf8) == "keep me")
  }

  @Test(
    "Successful runs surface an explicit file-output failure when no last-message file is produced")
  func runReturnsOutputFileFailureWhenLastMessageFileIsMissing() async throws {
    let temporaryDirectory = try makeTemporaryDirectory(named: "codexexec-last-message-missing")
    let outputFile = temporaryDirectory.appendingPathComponent("last.txt")
    let launcher = RecordingLauncher(
      output: CodexExecProcessOutput(
        exitStatus: 0,
        terminationSignal: nil,
        standardOutput: Data("final reply".utf8),
        standardError: Data("diagnostic".utf8)
      )
    )
    let client = CodexExecClient(
      configuration: CodexExecLaunchConfiguration(
        executableURL: temporaryDirectory.appendingPathComponent("codex")
      ),
      launcher: launcher
    )

    do {
      let handle = try await client.run(
        CodexExecRunRequest(
          promptInput: .text("hello"),
          outputLastMessageFile: outputFile
        )
      )
      _ = try await handle.waitForTermination()
      Issue.record("Expected an output-file failure.")
    } catch let error as CodexExecError {
      switch error {
      case .outputFileFailure(let path, let description, let partialObservation):
        #expect(path == outputFile)
        #expect(description.contains("Failed to read output-last-message file"))
        #expect(partialObservation?.finalMessageText == "final reply")
        #expect(partialObservation?.stderrText == "diagnostic")
      default:
        Issue.record("Expected an output-file failure.")
      }
    }
  }
}
