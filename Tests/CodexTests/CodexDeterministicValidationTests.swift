import Foundation
import Testing

@testable import Codex

@Suite("Codex Deterministic Validation")
struct CodexDeterministicValidationTests {
  @Test("Deterministic session does not require a live codex path")
  func deterministicSessionDoesNotRequireLiveCodexPath() async throws {
    let session = CodexDeterministicSession(
      clientOptions: CodexOptions(
        codexPathOverride: URL(fileURLWithPath: "/tmp/definitely-not-a-real-codex-binary"),
        environment: ["VALIDATION_MODE": "deterministic"]
      )
    )
    let reportedUsage = Usage(inputTokens: 1, cachedInputTokens: 0, outputTokens: 1)
    session.executor.usage = reportedUsage

    let bufferedTurn = try await session.run(.text("hello"))
    let streamedEvents = try await session.runStreamed(.text("again"))

    #expect(bufferedTurn.finalResponse == "hello")
    expectAgentMessageItem(bufferedTurn.items, text: "hello")
    #expect(bufferedTurn.usage == reportedUsage)
    #expect(session.thread.id != nil)
    #expect(streamedEvents.first == ThreadEvent.turnStarted)
    #expect(streamedEvents.count == 3)

    guard case .some(.turnCompleted(let usage)) = streamedEvents.last else {
      Issue.record("Expected final streamed event to be turnCompleted")
      return
    }

    #expect(usage == reportedUsage)
    guard case .itemCompleted(let item) = streamedEvents[1] else {
      Issue.record("Expected second streamed event to be itemCompleted")
      return
    }

    expectAgentMessageItem(item, text: "again")
    #expect(bufferedTurn.items.first?.id != item.id)
  }

  @Test(
    "Deterministic session validates environment, working-directory, trusted-repo, and schema seams"
  )
  func deterministicSessionValidatesPreparedContextAcceptanceMatrix() {
    let schema: CodexConfigObject = [
      "type": .string("object"),
      "properties": .object([
        "answer": .object(["type": .string("string")])
      ]),
    ]

    let session = CodexDeterministicSession(
      clientOptions: CodexOptions(
        codexPathOverride: URL(fileURLWithPath: "/tmp/fake-codex"),
        baseURL: URL(string: "https://example.invalid"),
        apiKey: "test-key",
        config: [
          "model": .string("client-model"),
          "sandbox_mode": .string("read-only"),
          "custom": .string("preserved"),
        ],
        environment: ["FROM_CLIENT": "1"]
      ),
      threadOptions: ThreadOptions(
        model: "thread-model",
        sandboxMode: "workspace-write",
        workingDirectory: URL(fileURLWithPath: "/tmp/workspace"),
        skipGitRepoCheck: true,
        approvalPolicy: "on-failure",
        additionalDirectories: [URL(fileURLWithPath: "/tmp/shared")]
      )
    )

    let context = session.preparedContext(
      turnOptions: TurnOptions(outputSchema: schema)
    )

    #expect(context.codexPathOverride == URL(fileURLWithPath: "/tmp/fake-codex"))
    #expect(context.baseURL == URL(string: "https://example.invalid"))
    #expect(context.apiKey == "test-key")
    #expect(context.environment == ["FROM_CLIENT": "1"])
    #expect(context.workingDirectory == URL(fileURLWithPath: "/tmp/workspace"))
    #expect(context.skipGitRepoCheck == true)
    #expect(context.additionalDirectories == [URL(fileURLWithPath: "/tmp/shared")])
    #expect(context.outputSchema == schema)
    #expect(context.config["model"] == .string("thread-model"))
    #expect(context.config["sandbox_mode"] == .string("workspace-write"))
    #expect(context.config["custom"] == .string("preserved"))
  }

  @Test("Deterministic session can inject buffered and streamed terminal failures")
  func deterministicSessionCanInjectTerminalFailures() async throws {
    let turnFailure = ThreadError(message: "turn failed")
    let turnFailureSession = CodexDeterministicSession()
    turnFailureSession.executor.failureMode = .turnFailed(turnFailure)

    do {
      _ = try await turnFailureSession.run(.text("hello"))
      Issue.record("Expected buffered deterministic session to throw ThreadError")
    } catch let error as ThreadError {
      #expect(error == turnFailure)
    } catch {
      Issue.record("Expected ThreadError, got: \(error)")
    }

    let streamFailure = ThreadError(message: "stream failed")
    let streamFailureSession = CodexDeterministicSession()
    streamFailureSession.executor.failureMode = .streamError(streamFailure)

    do {
      _ = try await streamFailureSession.runStreamed(.text("hello"))
      Issue.record("Expected streamed deterministic session to throw ThreadError")
    } catch let error as ThreadError {
      #expect(error == streamFailure)
    } catch {
      Issue.record("Expected ThreadError, got: \(error)")
    }
  }

  private final class CodexDeterministicSession {
    let codex: Codex
    let thread: CodexThread
    let executor: DeterministicCodexThreadExecutor

    init(
      clientOptions: CodexOptions = .init(),
      threadOptions: ThreadOptions = .init(),
      resumedID: String? = nil
    ) {
      codex = Codex(options: clientOptions)
      if let resumedID {
        thread = codex.resumeThread(resumedID, options: threadOptions)
      } else {
        thread = codex.startThread(options: threadOptions)
      }
      executor = configureDeterministicExecutor(
        thread,
        usage: Usage(
          inputTokens: 0,
          cachedInputTokens: 0,
          outputTokens: 0
        )
      )
    }

    func preparedContext(
      turnOptions: TurnOptions = .init()
    ) -> CodexThreadExecutionContext {
      thread.preparedTurnContext(turnOptions: turnOptions)
    }

    func run(
      _ input: Input,
      options: TurnOptions = .init()
    ) async throws -> Turn {
      try await thread.run(input, options: options)
    }

    func runStreamed(
      _ input: Input,
      options: TurnOptions = .init()
    ) async throws -> [ThreadEvent] {
      let stream = try await thread.runStreamed(input, options: options)
      return try await collectDeterministicStream(stream)
    }
  }

}
private func collectDeterministicStream<S: AsyncSequence>(
  _ stream: S
) async throws -> [S.Element] where S: Sendable {
  var values: [S.Element] = []

  for try await value in stream {
    values.append(value)
  }

  return values
}

private func expectAgentMessageItem(_ items: [ThreadItem], text: String) {
  #expect(items.count == 1)
  if let item = items.first {
    expectAgentMessageItem(item, text: text)
  }
}

private func expectAgentMessageItem(_ item: ThreadItem, text: String) {
  guard case .agentMessage(let agentMessage) = item else {
    Issue.record("Expected agentMessage item")
    return
  }

  #expect(!agentMessage.id.isEmpty)
  #expect(agentMessage.text == text)
}
