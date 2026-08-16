import Foundation
import Testing

@testable import CodexExec

@Suite("CodexExec")
struct CodexExecTests {
  @Test("Existing request initializer keeps user config by default")
  func existingRequestInitializerRemainsCompatible() {
    let options = CodexExecRequestOptions(ephemeral: true, fullAuto: true)

    #expect(!options.ignoreUserConfig)
  }

  @Test("Run keeps the public operation explicit and uses launch configuration")
  func runUsesExplicitRunKind() async throws {
    let launcher = RecordingLauncher()
    let executableURL = URL(fileURLWithPath: "/tmp/codex")
    let workingDirectory = URL(fileURLWithPath: "/tmp/workspace")
    let client = CodexExecClient(
      configuration: CodexExecLaunchConfiguration(
        executableURL: executableURL,
        environmentOverride: ["PATH": "/usr/bin"],
        apiKey: "test-key",
        defaultWorkingDirectory: workingDirectory
      ),
      launcher: launcher
    )
    let request = CodexExecRunRequest(promptInput: .text("hello"))

    let handle = try await client.run(request)
    let launches = await launcher.recordedLaunches()
    let launch = try #require(launches.first)
    let termination = try await handle.waitForTermination()

    #expect(launch.kind == .run(request))
    #expect(launch.executableURL == executableURL)
    #expect(launch.workingDirectory == workingDirectory)
    #expect(launch.environment["CODEX_API_KEY"] == "test-key")
    #expect(launch.standardInput == nil)
    #expect(launch.arguments == ["exec", "--cd", workingDirectory.path, "hello"])
    #expect(termination.operation == .run)
    #expect(termination.effectiveWorkingDirectory == workingDirectory)
  }

  @Test("Run maps the documented option surface in a stable order")
  func runMapsDocumentedSurface() async throws {
    let temporaryDirectory = try makeTemporaryDirectory(named: "codexexec-run-mapping")
    let executableURL = temporaryDirectory.appendingPathComponent("codex")
    let schemaFile = temporaryDirectory.appendingPathComponent("schema.json")
    let lastMessageFile = temporaryDirectory.appendingPathComponent("last.txt")
    let addDirOne = temporaryDirectory.appendingPathComponent("shared")
    let addDirTwo = temporaryDirectory.appendingPathComponent("fixtures")
    let imageOne = temporaryDirectory.appendingPathComponent("one.png")
    let imageTwo = temporaryDirectory.appendingPathComponent("two.png")
    let workingDirectory = temporaryDirectory.appendingPathComponent("project")
    try "{}".write(to: schemaFile, atomically: true, encoding: .utf8)

    let launcher = RecordingLauncher { _ in
      try "".write(to: lastMessageFile, atomically: true, encoding: .utf8)
      return CodexExecProcessOutput(
        exitStatus: 0,
        terminationSignal: nil,
        standardOutput: Data(
          #"{"type":"turn.completed","usage":{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0}}"#
            .utf8),
        standardError: Data()
      )
    }
    let client = CodexExecClient(
      configuration: CodexExecLaunchConfiguration(
        executableURL: executableURL,
        environmentOverride: ["PATH": "/usr/bin", "CUSTOM": "1"],
        apiKey: "api-key"
      ),
      launcher: launcher
    )
    let request = CodexExecRunRequest(
      promptInput: .textWithStdinContext(prompt: "ship it", stdin: "context"),
      outputMode: .jsonl,
      options: CodexExecRequestOptions(
        images: [imageOne, imageTwo],
        additionalWritableDirectories: [addDirOne, addDirTwo],
        approvalMode: "never",
        searchEnabled: true,
        enabledFeatures: ["alpha", "beta"],
        disabledFeatures: ["gamma"],
        model: "gpt-5",
        useOSS: true,
        workingDirectory: workingDirectory,
        colorMode: "never",
        dangerouslyBypassApprovalsAndSandbox: true,
        ephemeral: true,
        ignoreUserConfig: true,
        fullAuto: true,
        profile: "ci",
        sandboxMode: "workspace-write",
        skipGitRepoCheck: true,
        configOverrides: ["a=1", "b=2"]
      ),
      outputSchemaFile: schemaFile,
      outputLastMessageFile: lastMessageFile
    )

    let handle = try await client.run(request)
    let launches = await launcher.recordedLaunches()
    let launch = try #require(launches.first)
    let termination = try await handle.waitForTermination()

    #expect(launch.kind == .run(request))
    #expect(launch.executableURL == executableURL)
    #expect(launch.environment["CUSTOM"] == "1")
    #expect(launch.environment["CODEX_API_KEY"] == "api-key")
    #expect(launch.workingDirectory == workingDirectory)
    #expect(launch.standardInput == Data("context".utf8))
    #expect(
      launch.arguments == [
        "exec",
        "--json",
        "--output-schema", schemaFile.path,
        "--output-last-message", lastMessageFile.path,
        "--add-dir", addDirOne.path,
        "--add-dir", addDirTwo.path,
        "--ask-for-approval", "never",
        "--search",
        "--enable", "alpha",
        "--enable", "beta",
        "--disable", "gamma",
        "--model", "gpt-5",
        "--oss",
        "--profile", "ci",
        "--sandbox", "workspace-write",
        "--full-auto",
        "--dangerously-bypass-approvals-and-sandbox",
        "--ephemeral",
        "--ignore-user-config",
        "--color", "never",
        "--skip-git-repo-check",
        "--config", "a=1",
        "--config", "b=2",
        "--cd", workingDirectory.path,
        "--image", imageOne.path,
        "--image", imageTwo.path,
        "ship it",
      ]
    )
    #expect(termination.operation == .run)
    #expect(termination.effectiveWorkingDirectory == workingDirectory)
  }

  @Test("Run stdin prompt mode uses dash and stdin payload")
  func runMapsStdinPromptMode() async throws {
    let launcher = RecordingLauncher()
    let client = CodexExecClient(
      configuration: CodexExecLaunchConfiguration(
        executableURL: URL(fileURLWithPath: "/tmp/codex")
      ),
      launcher: launcher
    )
    let request = CodexExecRunRequest(promptInput: .stdin("stdin prompt"))

    let _ = try await client.run(request)
    let launches = await launcher.recordedLaunches()
    let launch = try #require(launches.first)

    #expect(launch.arguments == ["exec", "-"])
    #expect(launch.standardInput == Data("stdin prompt".utf8))
  }

  @Test("Resume maps selector, options, and prompt ordering explicitly")
  func resumeMapsDocumentedSurface() async throws {
    let temporaryDirectory = try makeTemporaryDirectory(named: "codexexec-resume-mapping")
    let image = temporaryDirectory.appendingPathComponent("one.png")
    let workingDirectory = temporaryDirectory.appendingPathComponent("project")
    let lastMessageFile = temporaryDirectory.appendingPathComponent("last.txt")
    let launcher = RecordingLauncher { _ in
      try "".write(to: lastMessageFile, atomically: true, encoding: .utf8)
      return CodexExecProcessOutput(
        exitStatus: 0,
        terminationSignal: nil,
        standardOutput: Data(
          #"{"type":"turn.completed","usage":{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0}}"#
            .utf8),
        standardError: Data()
      )
    }
    let client = CodexExecClient(
      configuration: CodexExecLaunchConfiguration(
        executableURL: temporaryDirectory.appendingPathComponent("codex"),
        defaultWorkingDirectory: temporaryDirectory.appendingPathComponent("default")
      ),
      launcher: launcher
    )
    let request = CodexExecResumeRequest(
      selector: .lastAll,
      promptInput: .stdin("resume prompt"),
      outputMode: .jsonl,
      options: CodexExecRequestOptions(
        images: [image],
        workingDirectory: workingDirectory,
        configOverrides: ["resume=true"]
      ),
      outputLastMessageFile: lastMessageFile
    )

    let handle = try await client.resume(request)
    let launches = await launcher.recordedLaunches()
    let launch = try #require(launches.first)
    let termination = try await handle.waitForTermination()

    #expect(launch.kind == .resume(request))
    #expect(launch.workingDirectory == workingDirectory)
    #expect(launch.standardInput == Data("resume prompt".utf8))
    #expect(
      launch.arguments == [
        "exec",
        "--json",
        "--output-last-message", lastMessageFile.path,
        "--config", "resume=true",
        "--cd", workingDirectory.path,
        "resume",
        "--last",
        "--all",
        "--image", image.path,
        "-",
      ]
    )
    #expect(termination.operation == .resume)
    #expect(termination.effectiveWorkingDirectory == workingDirectory)
  }

  @Test("Resume session identifier stays opaque and explicit")
  func resumeUsesExplicitSessionIdentifier() async throws {
    let launcher = RecordingLauncher()
    let client = CodexExecClient(
      configuration: CodexExecLaunchConfiguration(
        executableURL: URL(fileURLWithPath: "/tmp/codex")
      ),
      launcher: launcher
    )
    let request = CodexExecResumeRequest(
      selector: .sessionID("session-123"),
      promptInput: .text("follow up")
    )

    let handle = try await client.resume(request)
    let launches = await launcher.recordedLaunches()
    let launch = try #require(launches.first)
    let termination = try await handle.waitForTermination()

    #expect(launch.kind == .resume(request))
    #expect(launch.arguments == ["exec", "resume", "session-123", "follow up"])
    #expect(termination.operation == .resume)
  }

  @Test("Human-readable mode keeps stdout as the final message and stderr separate")
  func runInterpretsHumanReadableOutput() async throws {
    let launcher = RecordingLauncher(
      output: CodexExecProcessOutput(
        exitStatus: 0,
        terminationSignal: nil,
        standardOutput: Data("final reply".utf8),
        standardError: Data("progress line\nwarning line".utf8)
      )
    )
    let client = CodexExecClient(
      configuration: CodexExecLaunchConfiguration(
        executableURL: URL(fileURLWithPath: "/tmp/codex")
      ),
      launcher: launcher
    )

    let handle = try await client.run(CodexExecRunRequest(promptInput: .text("hello")))
    let lines = try await collectLines(from: handle.stdoutLines)
    let termination = try await handle.waitForTermination()

    #expect(lines == ["final reply"])
    #expect(termination.capturedStderrText == "progress line\nwarning line")
    #expect(termination.operation == .run)
  }

  @Test("JSONL mode decodes known events and preserves unknown variants")
  func runInterpretsJSONLStream() async throws {
    let unknownEventLine = #"{"type":"experimental.event","payload":true}"#
    let jsonl = [
      #"{"type":"thread.started","thread_id":"thread-1"}"#,
      #"{"type":"item.completed","item":{"id":"item-1","type":"agent_message","text":"final answer"}}"#,
      #"{"type":"item.updated","item":{"id":"item-2","type":"todo_list","items":[{"text":"ship WP4","completed":false}]}}"#,
      unknownEventLine,
      #"{"type":"item.started","item":{"id":"item-3","type":"collab_tool_call","tool":"spawn_agent"}}"#,
      #"{"type":"turn.completed","usage":{"input_tokens":3,"cached_input_tokens":1,"output_tokens":2}}"#,
    ].joined(separator: "\n")

    let launcher = RecordingLauncher(
      output: CodexExecProcessOutput(
        exitStatus: 0,
        terminationSignal: nil,
        standardOutput: Data(jsonl.utf8),
        standardError: Data("diagnostic".utf8)
      )
    )
    let client = CodexExecClient(
      configuration: CodexExecLaunchConfiguration(
        executableURL: URL(fileURLWithPath: "/tmp/codex")
      ),
      launcher: launcher
    )

    let observed = try await observeJSONLHandle(
      try await client.run(
        CodexExecRunRequest(
          promptInput: .text("hello"),
          outputMode: .jsonl
        )
      ))

    #expect(observed.termination.capturedStderrText == "diagnostic")
    #expect(observed.finalMessageText == "final answer")
    #expect(observed.resolvedSessionID == "thread-1")
    #expect(observed.events.count == 6)
    #expect(observed.events[0] == .threadStarted(id: "thread-1"))
    #expect(
      observed.events[1] == .itemCompleted(.agentMessage(.init(id: "item-1", text: "final answer")))
    )
    #expect(
      observed.events[2]
        == .itemUpdated(
          .todoList(.init(id: "item-2", items: [.init(text: "ship WP4", completed: false)])))
    )
    #expect(observed.events[3] == .unknown(type: "experimental.event", rawJSON: unknownEventLine))

    switch observed.events[4] {
    case .itemStarted(.unknown(let item)):
      #expect(item.kind == "collab_tool_call")
      #expect(item.id == "item-3")
      #expect(item.rawJSON?.contains(#""type":"collab_tool_call""#) == true)
    default:
      Issue.record("Expected an unknown collab-tool item event.")
    }
    #expect(
      observed.events[5]
        == .turnCompleted(usage: .init(inputTokens: 3, cachedInputTokens: 1, outputTokens: 2)))
  }

  @Test("Exec JSON payloads preserve Int64 integers separately from floating point")
  func execJSONPayloadsPreserveNumberKinds() throws {
    let line =
      #"{"type":"item.completed","item":{"id":"item-1","type":"mcp_tool_call","server":"fixture","tool":"numbers","arguments":{"integer":9223372036854775807,"floating":0.5,"enabled":true},"status":"completed"}}"#

    let event = try CodexExecJSONLDecoder().decodeLine(line)
    guard case .itemCompleted(.mcpToolCall(let item)) = event else {
      Issue.record("Expected a completed MCP tool-call item.")
      return
    }

    #expect(
      item.arguments
        == .object([
          "integer": .integer(Int64.max),
          "floating": .double(0.5),
          "enabled": .bool(true),
        ]))
  }

  @Test("Malformed JSONL fails deterministically without entering later failure semantics")
  func runRejectsMalformedJSONL() async throws {
    let launcher = RecordingLauncher(
      output: CodexExecProcessOutput(
        exitStatus: 0,
        terminationSignal: nil,
        standardOutput: Data(
          #"{"type":"thread.started","thread_id":"thread-1"}"#.appending("\nnot-json").utf8),
        standardError: Data()
      )
    )
    let client = CodexExecClient(
      configuration: CodexExecLaunchConfiguration(
        executableURL: URL(fileURLWithPath: "/tmp/codex")
      ),
      launcher: launcher
    )

    do {
      let handle = try await client.run(
        CodexExecRunRequest(
          promptInput: .text("hello"),
          outputMode: .jsonl
        )
      )
      _ = try await handle.waitForTermination()
      Issue.record("Expected a malformed JSONL error.")
    } catch let error as CodexExecError {
      switch error {
      case .malformedJSONL(let line, let partialObservation):
        #expect(line == "not-json")
        #expect(partialObservation?.resolvedSessionID == "thread-1")
        #expect(partialObservation?.events == [.threadStarted(id: "thread-1")])
      default:
        Issue.record("Expected a malformed JSONL error.")
      }
    }
  }

  @Test("JSONL mode does not report success without a completed turn")
  func runRejectsJSONLSuccessWithoutCompletedTurn() async throws {
    let jsonl = [
      #"{"type":"thread.started","thread_id":"thread-1"}"#,
      #"{"type":"turn.started"}"#,
      #"{"type":"item.completed","item":{"id":"item-1","type":"agent_message","text":"partial answer"}}"#,
    ].joined(separator: "\n")
    let launcher = RecordingLauncher(
      output: CodexExecProcessOutput(
        exitStatus: 0,
        terminationSignal: nil,
        standardOutput: Data(jsonl.utf8),
        standardError: Data("execution stopped early".utf8)
      )
    )
    let client = CodexExecClient(
      configuration: CodexExecLaunchConfiguration(
        executableURL: URL(fileURLWithPath: "/tmp/codex")
      ),
      launcher: launcher
    )

    do {
      let handle = try await client.run(
        CodexExecRunRequest(
          promptInput: .text("hello"),
          outputMode: .jsonl
        )
      )
      _ = try await handle.waitForTermination()
      Issue.record("Expected an interrupted failure.")
    } catch let error as CodexExecError {
      switch error {
      case .interrupted(let partialObservation):
        #expect(partialObservation?.stderrText == "execution stopped early")
        #expect(partialObservation?.resolvedSessionID == "thread-1")
        #expect(partialObservation?.finalMessageText == "partial answer")
        #expect(
          partialObservation?.events == [
            .threadStarted(id: "thread-1"),
            .turnStarted,
            .itemCompleted(.agentMessage(.init(id: "item-1", text: "partial answer"))),
          ]
        )
      default:
        Issue.record("Expected an interrupted failure.")
      }
    }
  }

  @Test("Non-zero exit surfaces a failure and preserves partial observations")
  func runReturnsNonZeroExitFailureWithPartialObservation() async throws {
    let launcher = RecordingLauncher(
      output: CodexExecProcessOutput(
        exitStatus: 1,
        terminationSignal: nil,
        standardOutput: Data("partial answer".utf8),
        standardError: Data("synthetic server error".utf8)
      )
    )
    let client = CodexExecClient(
      configuration: CodexExecLaunchConfiguration(
        executableURL: URL(fileURLWithPath: "/tmp/codex")
      ),
      launcher: launcher
    )

    do {
      let handle = try await client.run(CodexExecRunRequest(promptInput: .text("hello")))
      _ = try await handle.waitForTermination()
      Issue.record("Expected a non-zero exit failure.")
    } catch let error as CodexExecError {
      switch error {
      case .nonZeroExit(let code, let stderr, let partialObservation):
        #expect(code == 1)
        #expect(stderr == "synthetic server error")
        #expect(partialObservation?.stderrText == "synthetic server error")
        #expect(partialObservation?.finalMessageText == "partial answer")
        #expect(partialObservation?.events.isEmpty == true)
      default:
        Issue.record("Expected a non-zero exit failure.")
      }
    }
  }

  @Test("Resume miss surfaces an explicit resume target failure")
  func resumeMissReturnsExplicitFailure() async throws {
    let jsonl = [
      #"{"type":"thread.started","thread_id":"thread-resume-miss"}"#,
      #"{"type":"item.completed","item":{"id":"item-1","type":"agent_message","text":"partial follow-up"}}"#,
    ].joined(separator: "\n")
    let launcher = RecordingLauncher(
      output: CodexExecProcessOutput(
        exitStatus: 1,
        terminationSignal: nil,
        standardOutput: Data(jsonl.utf8),
        standardError: Data("thread not found: session-123".utf8)
      )
    )
    let client = CodexExecClient(
      configuration: CodexExecLaunchConfiguration(
        executableURL: URL(fileURLWithPath: "/tmp/codex")
      ),
      launcher: launcher
    )
    let request = CodexExecResumeRequest(
      selector: .sessionID("session-123"),
      promptInput: .text("follow up"),
      outputMode: .jsonl
    )

    do {
      let handle = try await client.resume(request)
      _ = try await handle.waitForTermination()
      Issue.record("Expected an explicit resume-target-not-found failure.")
    } catch let error as CodexExecError {
      switch error {
      case .resumeTargetNotFound(let selector, let partialObservation):
        #expect(selector == .sessionID("session-123"))
        #expect(partialObservation?.stderrText == "thread not found: session-123")
        #expect(partialObservation?.resolvedSessionID == "thread-resume-miss")
        #expect(partialObservation?.finalMessageText == "partial follow-up")
        #expect(
          partialObservation?.events == [
            .threadStarted(id: "thread-resume-miss"),
            .itemCompleted(.agentMessage(.init(id: "item-1", text: "partial follow-up"))),
          ]
        )
      default:
        Issue.record("Expected an explicit resume-target-not-found failure.")
      }
    }
  }

  @Test("Caller cancellation stays distinct from upstream interruption")
  func runReturnsCancelledWhenLaunchIsCancelled() async throws {
    let launcher = RecordingLauncher { _ in
      throw CodexExecLaunchCancelled()
    }
    let client = CodexExecClient(
      configuration: CodexExecLaunchConfiguration(
        executableURL: URL(fileURLWithPath: "/tmp/codex")
      ),
      launcher: launcher
    )

    do {
      let handle = try await client.run(CodexExecRunRequest(promptInput: .text("hello")))
      _ = try await handle.waitForTermination()
      Issue.record("Expected a cancelled failure.")
    } catch let error as CodexExecError {
      #expect(error == .cancelled(partialObservation: nil))
    }
  }

  @Test("System launcher propagates caller task cancellation to the child process")
  func runCancelsRealChildProcess() async throws {
    let temporaryDirectory = try makeTemporaryDirectory(named: "codexexec-system-cancel")
    let executableURL = try makeExecutableScript(
      in: temporaryDirectory,
      contents: """
        #!/bin/sh
        exec sleep 10
        """
    )
    let client = CodexExecClient(
      configuration: CodexExecLaunchConfiguration(
        executableURL: executableURL
      )
    )

    let task = Task {
      let handle = try await client.run(CodexExecRunRequest(promptInput: .text("hello")))
      return try await handle.waitForTermination()
    }

    try await Task.sleep(nanoseconds: 100_000_000)
    task.cancel()

    do {
      _ = try await task.value
      Issue.record("Expected a cancelled failure.")
    } catch let error as CodexExecError {
      switch error {
      case .cancelled(let partialObservation):
        #expect(partialObservation?.stderrText == "")
        #expect(partialObservation?.resolvedSessionID == nil)
        #expect(partialObservation?.events == [])
      default:
        Issue.record("Expected a cancelled failure.")
      }
    }
  }

  @Test("Cancelled launches preserve partial observations when output was already captured")
  func runReturnsCancelledWithPartialObservationFromCapturedOutput() async throws {
    let jsonl = #"{"type":"thread.started","thread_id":"thread-cancel"}"#
    let launcher = RecordingLauncher { _ in
      throw CodexExecLaunchCancelled(
        processOutput: CodexExecProcessOutput(
          exitStatus: 0,
          terminationSignal: nil,
          standardOutput: Data(jsonl.utf8),
          standardError: Data("progress before cancel".utf8)
        )
      )
    }
    let client = CodexExecClient(
      configuration: CodexExecLaunchConfiguration(
        executableURL: URL(fileURLWithPath: "/tmp/codex")
      ),
      launcher: launcher
    )

    do {
      let handle = try await client.run(
        CodexExecRunRequest(
          promptInput: .text("hello"),
          outputMode: .jsonl
        )
      )
      _ = try await handle.waitForTermination()
      Issue.record("Expected a cancelled failure.")
    } catch let error as CodexExecError {
      switch error {
      case .cancelled(let partialObservation):
        #expect(partialObservation?.stderrText == "progress before cancel")
        #expect(partialObservation?.resolvedSessionID == "thread-cancel")
        #expect(partialObservation?.events == [.threadStarted(id: "thread-cancel")])
      default:
        Issue.record("Expected a cancelled failure.")
      }
    }
  }

  @Test("Upstream interruption is surfaced distinctly and preserves partial observations")
  func runReturnsInterruptedForInterruptedExecution() async throws {
    let launcher = RecordingLauncher(
      output: CodexExecProcessOutput(
        exitStatus: 1,
        terminationSignal: nil,
        standardOutput: Data("partial answer".utf8),
        standardError: Data("turn interrupted".utf8)
      )
    )
    let client = CodexExecClient(
      configuration: CodexExecLaunchConfiguration(
        executableURL: URL(fileURLWithPath: "/tmp/codex")
      ),
      launcher: launcher
    )

    do {
      let handle = try await client.run(CodexExecRunRequest(promptInput: .text("hello")))
      _ = try await handle.waitForTermination()
      Issue.record("Expected an interrupted failure.")
    } catch let error as CodexExecError {
      switch error {
      case .interrupted(let partialObservation):
        #expect(partialObservation?.stderrText == "turn interrupted")
        #expect(partialObservation?.finalMessageText == "partial answer")
      default:
        Issue.record("Expected an interrupted failure.")
      }
    }
  }

  @Test("A signaled child process is not reclassified as caller cancellation")
  func runTreatsTerminationSignalAsInterruptedNotCancelled() async throws {
    let launcher = RecordingLauncher(
      output: CodexExecProcessOutput(
        exitStatus: nil,
        terminationSignal: 15,
        standardOutput: Data("partial answer".utf8),
        standardError: Data("received SIGTERM".utf8)
      )
    )
    let client = CodexExecClient(
      configuration: CodexExecLaunchConfiguration(
        executableURL: URL(fileURLWithPath: "/tmp/codex")
      ),
      launcher: launcher
    )

    do {
      let handle = try await client.run(CodexExecRunRequest(promptInput: .text("hello")))
      _ = try await handle.waitForTermination()
      Issue.record("Expected an interrupted failure.")
    } catch let error as CodexExecError {
      switch error {
      case .interrupted(let partialObservation):
        #expect(partialObservation?.stderrText == "received SIGTERM")
        #expect(partialObservation?.finalMessageText == "partial answer")
      case .cancelled:
        Issue.record("A signaled child process must not be classified as caller cancellation.")
      default:
        Issue.record("Expected an interrupted failure.")
      }
    }
  }

  @Test("Invalid output schema file fails before launch")
  func runRejectsMissingOutputSchemaFile() async throws {
    let launcher = RecordingLauncher()
    let client = CodexExecClient(
      configuration: CodexExecLaunchConfiguration(
        executableURL: URL(fileURLWithPath: "/tmp/codex")
      ),
      launcher: launcher
    )
    let schemaFile = URL(fileURLWithPath: "/tmp/codexexec-schema-missing-\(UUID().uuidString).json")

    do {
      _ = try await client.run(
        CodexExecRunRequest(
          promptInput: .text("hello"),
          outputSchemaFile: schemaFile
        )
      )
      Issue.record("Expected an invalid invocation failure.")
    } catch let error as CodexExecError {
      switch error {
      case .invalidInvocation(let description):
        #expect(description.contains("Failed to read output schema file"))
      default:
        Issue.record("Expected an invalid invocation failure.")
      }
    }

    let launches = await launcher.recordedLaunches()
    #expect(launches.isEmpty)
  }

  @Test("Invalid schema JSON fails before launch")
  func runRejectsInvalidSchemaJSON() async throws {
    let launcher = RecordingLauncher()
    let client = CodexExecClient(
      configuration: CodexExecLaunchConfiguration(
        executableURL: URL(fileURLWithPath: "/tmp/codex")
      ),
      launcher: launcher
    )
    let temporaryDirectory = try makeTemporaryDirectory(named: "codexexec-invalid-schema")
    let schemaFile = temporaryDirectory.appendingPathComponent("schema.json")
    try "not-json".write(to: schemaFile, atomically: true, encoding: .utf8)

    do {
      _ = try await client.run(
        CodexExecRunRequest(
          promptInput: .text("hello"),
          outputSchemaFile: schemaFile
        )
      )
      Issue.record("Expected an invalid invocation failure.")
    } catch let error as CodexExecError {
      switch error {
      case .invalidInvocation(let description):
        #expect(description.contains("is not valid JSON"))
      default:
        Issue.record("Expected an invalid invocation failure.")
      }
    }

    let launches = await launcher.recordedLaunches()
    #expect(launches.isEmpty)
  }

  @Test("Successful run verifies the output-last-message file")
  func runVerifiesOutputLastMessageFileOnSuccess() async throws {
    let temporaryDirectory = try makeTemporaryDirectory(named: "codexexec-last-message-success")
    let outputFile = temporaryDirectory.appendingPathComponent("last.txt")
    let launcher = RecordingLauncher { _ in
      try "final reply".write(to: outputFile, atomically: true, encoding: .utf8)
      return CodexExecProcessOutput(
        exitStatus: 0,
        terminationSignal: nil,
        standardOutput: Data("final reply".utf8),
        standardError: Data()
      )
    }
    let client = CodexExecClient(
      configuration: CodexExecLaunchConfiguration(
        executableURL: temporaryDirectory.appendingPathComponent("codex")
      ),
      launcher: launcher
    )

    let handle = try await client.run(
      CodexExecRunRequest(
        promptInput: .text("hello"),
        outputLastMessageFile: outputFile
      )
    )
    let lines = try await collectLines(from: handle.stdoutLines)
    let termination = try await handle.waitForTermination()

    #expect(lines == ["final reply"])
    #expect(termination.operation == .run)
    #expect(try String(contentsOf: outputFile, encoding: .utf8) == "final reply")
  }

  @Test("Output-last-message verification failure is explicit and preserves partial observations")
  func runReturnsOutputFileFailureWhenLastMessageFileDoesNotMatch() async throws {
    let temporaryDirectory = try makeTemporaryDirectory(named: "codexexec-last-message-failure")
    let outputFile = temporaryDirectory.appendingPathComponent("last.txt")
    let launcher = RecordingLauncher { _ in
      try "different reply".write(to: outputFile, atomically: true, encoding: .utf8)
      return CodexExecProcessOutput(
        exitStatus: 0,
        terminationSignal: nil,
        standardOutput: Data("final reply".utf8),
        standardError: Data("diagnostic".utf8)
      )
    }
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
        #expect(description.contains("did not match"))
        #expect(partialObservation?.finalMessageText == "final reply")
        #expect(partialObservation?.stderrText == "diagnostic")
      default:
        Issue.record("Expected an output-file failure.")
      }
    }
  }
}
