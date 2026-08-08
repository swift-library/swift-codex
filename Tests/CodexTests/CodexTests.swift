import Foundation
import Testing

@testable import Codex

@Suite("Codex")
struct CodexTests {
  @Test("Started threads resolve and preserve a stable id")
  func startedThreadResolvesStableID() async throws {
    let codex = Codex()
    let started = startDeterministicThread(codex)

    #expect(started.id == nil)

    let firstTurn = try await started.run(.text("hello"))
    let resolvedID = started.id

    #expect(resolvedID != nil)
    #expect(firstTurn.finalResponse == "hello")
    expectAgentMessageItem(firstTurn.items, text: "hello")
    #expect(firstTurn.usage == deterministicDefaultUsage())

    let secondTurn = try await started.run(.text("again"))
    #expect(started.id == resolvedID)
    #expect(secondTurn.finalResponse == "again")
    #expect(secondTurn.usage == deterministicDefaultUsage())
    #expect(firstTurn.items.first?.id != secondTurn.items.first?.id)
  }

  @Test("runStreamed resolves a new thread and resumeThread preserves explicit id")
  func streamedRunResolvesAndResumePreservesID() async throws {
    let codex = Codex()
    let started = startDeterministicThread(codex)
    let resumed = resumeDeterministicThread(codex, "thread-123")
    deterministicExecutor(for: started).interEventDelayNanoseconds = 50_000_000

    #expect(resumed.id == "thread-123")

    let events = try await started.runStreamed(.items([.text("hello")]))
    #expect(started.id == nil)
    var collectedEvents: [ThreadEvent] = []

    for try await event in events {
      collectedEvents.append(event)
    }

    if case .some(.threadStarted(let emittedID)) = collectedEvents.first {
      #expect(started.id == emittedID)
    } else {
      Issue.record("Expected first streamed event to resolve a new thread id")
    }

    _ = try await resumed.run(.text("hello"))
    #expect(resumed.id == "thread-123")
  }

  @Test("fresh thread id stays nil when the first buffered turn is cancelled before start")
  func cancelledFreshRunDoesNotResolveThreadID() async throws {
    let codex = Codex()
    let thread = startDeterministicThread(codex)
    deterministicExecutor(for: thread).interEventDelayNanoseconds = 50_000_000

    let task = Task {
      try await thread.run(.text("hello"))
    }

    try await Task.sleep(nanoseconds: 1_000_000)
    #expect(thread.id == nil)
    task.cancel()

    do {
      _ = try await task.value
      Issue.record("Expected run() to throw CancellationError")
    } catch is CancellationError {
      #expect(thread.id == nil)
    } catch {
      Issue.record("Expected CancellationError, got: \(error)")
    }
  }

  @Test("runStreamed emits ordered events for a new thread")
  func streamedRunEmitsOrderedEvents() async throws {
    let codex = Codex()
    let thread = startDeterministicThread(codex)
    let events = try await thread.runStreamed(.text("hello"))
    let collected = try await collect(events)

    #expect(collected.count == 4)

    if case .some(.threadStarted(let id)) = collected.first {
      #expect(thread.id == id)
    } else {
      Issue.record("Expected first event to be threadStarted")
    }

    #expect(collected[1] == ThreadEvent.turnStarted)
    expectCompletedAgentMessageEvent(collected[2], text: "hello")
    expectTurnCompletedUsage(
      collected[3],
      expected: deterministicDefaultUsage()
    )
  }

  @Test("Buffered run stays aligned with completed streamed turn output")
  func bufferedRunAlignsWithStreamedCompletedTurn() async throws {
    let codex = Codex()
    let bufferedThread = startDeterministicThread(codex)
    let streamedThread = startDeterministicThread(codex)
    let input: Input = .items([
      .text("first"),
      .localImage(URL(fileURLWithPath: "/tmp/example.png")),
      .text("second"),
    ])

    let bufferedTurn = try await bufferedThread.run(input)
    let events = try await streamedThread.runStreamed(input)
    let collected = try await collect(events)

    guard case .some(.turnCompleted(let usage)) = collected.last else {
      Issue.record("Expected last streamed event to be turnCompleted")
      return
    }

    #expect(usage == bufferedTurn.usage)
    #expect(collected.count == 4)
    #expect(bufferedTurn.items.count == 1)
    expectCompletedAgentMessageEvent(collected[2], text: bufferedTurn.finalResponse)
    #expect(bufferedTurn.usage == deterministicDefaultUsage())
  }

  @Test("resumed thread handles do not reuse assistant message item ids")
  func resumedThreadHandlesDoNotReuseItemIDs() async throws {
    let codex = Codex()
    let firstHandle = resumeDeterministicThread(codex, "thread-123")
    let secondHandle = resumeDeterministicThread(codex, "thread-123")

    let firstTurn = try await firstHandle.run(.text("hello"))
    let secondTurn = try await secondHandle.run(.text("again"))

    guard let firstItem = firstTurn.items.first, let secondItem = secondTurn.items.first else {
      Issue.record("Expected both resumed turns to produce a completed item")
      return
    }

    #expect(firstHandle.id == "thread-123")
    #expect(secondHandle.id == "thread-123")
    #expect(firstItem.id != secondItem.id)
    #expect(firstItem.kind == .agentMessage)
    #expect(secondItem.kind == .agentMessage)
  }

  @Test("runStreamed on a resumed thread does not emit threadStarted")
  func resumedThreadStreamDoesNotEmitThreadStarted() async throws {
    let codex = Codex()
    let thread = resumeDeterministicThread(codex, "thread-123")
    let events = try await thread.runStreamed(.text("hello"))
    let collected = try await collect(events)

    #expect(collected.first != ThreadEvent.threadStarted(id: "thread-123"))
    #expect(thread.id == "thread-123")
    #expect(collected.first == ThreadEvent.turnStarted)
  }

  @Test("Thread options override overlapping client config in the prepared context")
  func threadOptionsOverrideClientConfig() {
    let codex = Codex(
      options: CodexOptions(
        codexPathOverride: URL(fileURLWithPath: "/tmp/codex"),
        baseURL: URL(string: "https://example.invalid"),
        apiKey: "test-key",
        config: [
          "model": .string("client-model"),
          "sandbox_mode": .string("read-only"),
          "model_reasoning_effort": .string("minimal"),
          "web_search": .string("disabled"),
          "approval_policy": .string("never"),
          "sandbox_workspace_write": .object(["network_access": .bool(false)]),
          "custom": .string("keep-me"),
        ],
        environment: ["FROM_CLIENT": "1"]
      )
    )
    let thread = codex.startThread(
      options: ThreadOptions(
        model: "thread-model",
        sandboxMode: "workspace-write",
        workingDirectory: URL(fileURLWithPath: "/tmp/workspace"),
        skipGitRepoCheck: true,
        modelReasoningEffort: "high",
        networkAccessEnabled: true,
        webSearchMode: "live",
        approvalPolicy: "on-request",
        additionalDirectories: [URL(fileURLWithPath: "/tmp/shared")]
      )
    )
    configureDeterministicSuccess(thread)

    let context = thread.preparedTurnContext()

    #expect(context.codexPathOverride == URL(fileURLWithPath: "/tmp/codex"))
    #expect(context.baseURL == URL(string: "https://example.invalid"))
    #expect(context.apiKey == "test-key")
    #expect(context.environment == ["FROM_CLIENT": "1"])
    #expect(context.workingDirectory == URL(fileURLWithPath: "/tmp/workspace"))
    #expect(context.skipGitRepoCheck)
    #expect(context.additionalDirectories == [URL(fileURLWithPath: "/tmp/shared")])
    #expect(context.model == "thread-model")
    #expect(context.sandboxMode == "workspace-write")
    #expect(context.modelReasoningEffort == "high")
    #expect(context.networkAccessEnabled == true)
    #expect(context.webSearchMode == "live")
    #expect(context.approvalPolicy == "on-request")
    #expect(context.outputSchema == nil)
    #expect(context.config["model"] == .string("thread-model"))
    #expect(context.config["sandbox_mode"] == .string("workspace-write"))
    #expect(context.config["model_reasoning_effort"] == .string("high"))
    #expect(context.config["web_search"] == .string("live"))
    #expect(context.config["approval_policy"] == .string("on-request"))
    #expect(context.config["custom"] == .string("keep-me"))
    #expect(
      context.config["sandbox_workspace_write"]
        == .object(["network_access": .bool(true)])
    )
  }

  @Test("Turn options stay per-turn and do not mutate the thread's long-lived context")
  func turnOptionsStayPerTurnOnly() {
    let codex = Codex(
      options: CodexOptions(
        config: ["model": .string("client-model")]
      )
    )
    let thread = codex.startThread(
      options: ThreadOptions(model: "thread-model")
    )
    configureDeterministicSuccess(thread)
    let schema: CodexConfigObject = [
      "type": .string("object"),
      "properties": .object([
        "answer": .object(["type": .string("string")])
      ]),
    ]

    let firstContext = thread.preparedTurnContext(
      turnOptions: TurnOptions(outputSchema: schema)
    )
    let secondContext = thread.preparedTurnContext()

    #expect(firstContext.outputSchema == schema)
    #expect(secondContext.outputSchema == nil)
    #expect(firstContext.model == "thread-model")
    #expect(secondContext.model == "thread-model")
    #expect(firstContext.config["model"] == .string("thread-model"))
    #expect(secondContext.config["model"] == .string("thread-model"))
  }

  @Test("run throws CancellationError when the caller task is cancelled before execution")
  func runThrowsCancellationErrorBeforeExecution() async throws {
    let codex = Codex()
    let thread = startDeterministicThread(codex)

    let task = Task {
      try await thread.run(.text("hello"))
    }

    task.cancel()

    do {
      _ = try await task.value
      Issue.record("Expected run() to throw CancellationError")
    } catch is CancellationError {
      // expected
    } catch {
      Issue.record("Expected CancellationError, got: \(error)")
    }
  }

  @Test("runStreamed throws CancellationError when the caller task is cancelled before execution")
  func runStreamedThrowsCancellationErrorBeforeExecution() async throws {
    let codex = Codex()
    let thread = startDeterministicThread(codex)

    let task = Task {
      let stream = try await thread.runStreamed(.text("hello"))
      return try await collect(stream)
    }

    task.cancel()

    do {
      _ = try await task.value
      Issue.record("Expected runStreamed() to throw CancellationError")
    } catch is CancellationError {
      // expected
    } catch {
      Issue.record("Expected CancellationError, got: \(error)")
    }
  }

  @Test("run throws CancellationError when cancelled during execution")
  func runThrowsCancellationErrorDuringExecution() async throws {
    let codex = Codex()
    let thread = startDeterministicThread(codex)
    deterministicExecutor(for: thread).interEventDelayNanoseconds = 10_000_000

    let task = Task {
      try await thread.run(.items([.text("first"), .text("second")]))
    }

    try await Task.sleep(nanoseconds: 1_000_000)
    task.cancel()

    do {
      _ = try await task.value
      Issue.record("Expected run() to throw CancellationError during execution")
    } catch is CancellationError {
      // expected
    } catch {
      Issue.record("Expected CancellationError, got: \(error)")
    }
  }

  @Test("run returns the completed turn when cancellation arrives after terminal success")
  func runReturnsCompletedTurnAfterTerminalSuccessCancellation() async throws {
    let codex = Codex()
    let thread = startDeterministicThread(codex)
    let successObserved = OneShotSignal()
    let executor = deterministicExecutor(for: thread)
    executor.postTerminalSuccessDelayNanoseconds = 50_000_000
    executor.onTerminalSuccessObserved = {
      Task {
        await successObserved.signal()
      }
    }

    let task = Task {
      try await thread.run(.text("hello"))
    }

    await successObserved.wait()
    task.cancel()

    let turn = try await task.value
    #expect(turn.finalResponse == "hello")
    expectAgentMessageItem(turn.items, text: "hello")
  }

  @Test(
    "runStreamed throws CancellationError when the originating caller task is cancelled during iteration"
  )
  func runStreamedThrowsCancellationErrorWhenOriginatingTaskIsCancelled() async throws {
    let codex = Codex()
    let thread = startDeterministicThread(codex)
    deterministicExecutor(for: thread).interEventDelayNanoseconds = 10_000_000
    let handoff = StreamHandoff<StreamedTurn>()

    let originatingTask = Task {
      let stream = try await thread.runStreamed(.items([.text("first"), .text("second")]))
      await handoff.publish(stream)
      try await Task.sleep(nanoseconds: 1_000_000_000)
    }
    let stream = await handoff.wait()
    let consumerTask = Task {
      try await collect(stream)
    }

    try await Task.sleep(nanoseconds: 12_000_000)
    originatingTask.cancel()

    do {
      _ = try await consumerTask.value
      Issue.record(
        "Expected runStreamed() to throw CancellationError after originating task cancellation")
    } catch is CancellationError {
      // expected
    } catch {
      Issue.record("Expected CancellationError, got: \(error)")
    }

    _ = await originatingTask.result
  }

  @Test("runStreamed finishes successfully when cancellation arrives after terminal success")
  func runStreamedFinishesSuccessfullyAfterTerminalSuccessCancellation() async throws {
    let codex = Codex()
    let thread = startDeterministicThread(codex)
    let successObserved = OneShotSignal()
    let executor = deterministicExecutor(for: thread)
    executor.postTerminalSuccessDelayNanoseconds = 50_000_000
    executor.onTerminalSuccessObserved = {
      Task {
        await successObserved.signal()
      }
    }
    let handoff = StreamHandoff<StreamedTurn>()

    let originatingTask = Task {
      let stream = try await thread.runStreamed(.text("hello"))
      await handoff.publish(stream)
      try await Task.sleep(nanoseconds: 1_000_000_000)
    }
    let stream = await handoff.wait()
    let consumerTask = Task {
      try await collect(stream)
    }

    await successObserved.wait()
    originatingTask.cancel()

    let collected = try await consumerTask.value
    #expect(collected.count == 4)
    #expect(collected.last == .turnCompleted(usage: deterministicDefaultUsage()))

    _ = await originatingTask.result
  }

  @Test("run throws ThreadError when the turn fails")
  func runThrowsThreadErrorOnTurnFailure() async throws {
    let codex = Codex()
    let thread = startDeterministicThread(codex)
    let expected = ThreadError(message: "turn failed")
    deterministicExecutor(for: thread).failureMode = .turnFailed(expected)

    do {
      _ = try await thread.run(.text("hello"))
      Issue.record("Expected run() to throw ThreadError on turn failure")
    } catch let error as ThreadError {
      #expect(error == expected)
    } catch {
      Issue.record("Expected ThreadError, got: \(error)")
    }
  }

  @Test("runStreamed yields turnFailed and completes without a thrown stream error")
  func runStreamedYieldsTurnFailedEvent() async throws {
    let codex = Codex()
    let thread = startDeterministicThread(codex)
    let expected = ThreadError(message: "turn failed")
    deterministicExecutor(for: thread).failureMode = .turnFailed(expected)

    let stream = try await thread.runStreamed(.text("hello"))
    let collected = try await collect(stream)

    #expect(collected.count == 3)
    #expect(collected[1] == ThreadEvent.turnStarted)
    #expect(collected[2] == ThreadEvent.turnFailed(expected))
  }

  @Test("run throws ThreadError when the stream reports a terminal error")
  func runThrowsThreadErrorOnStreamError() async throws {
    let codex = Codex()
    let thread = startDeterministicThread(codex)
    let expected = ThreadError(message: "stream failed")
    deterministicExecutor(for: thread).failureMode = .streamError(expected)

    do {
      _ = try await thread.run(.text("hello"))
      Issue.record("Expected run() to throw ThreadError on stream error")
    } catch let error as ThreadError {
      #expect(error == expected)
    } catch {
      Issue.record("Expected ThreadError, got: \(error)")
    }
  }

  @Test("runStreamed yields error and then terminates by throwing ThreadError")
  func runStreamedYieldsErrorEventThenThrows() async throws {
    let codex = Codex()
    let thread = startDeterministicThread(codex)
    let expected = ThreadError(message: "stream failed")
    deterministicExecutor(for: thread).failureMode = .streamError(expected)

    let stream = try await thread.runStreamed(.text("hello"))
    var iterator = stream.makeAsyncIterator()

    _ = try await iterator.next()
    let second = try await iterator.next()
    let third = try await iterator.next()

    #expect(second == .some(ThreadEvent.turnStarted))
    #expect(third == .some(ThreadEvent.error(expected)))

    do {
      _ = try await iterator.next()
      Issue.record("Expected stream iteration to throw ThreadError after error event")
    } catch let error as ThreadError {
      #expect(error == expected)
    } catch {
      Issue.record("Expected ThreadError, got: \(error)")
    }
  }

  @Test("Structured input joins text with blank lines and preserves image order in buffered output")
  func structuredInputNormalizesIntoBufferedTurn() async throws {
    let codex = Codex()
    let thread = startDeterministicThread(codex)
    let imageURL = URL(fileURLWithPath: "/tmp/example.png")

    let turn = try await thread.run(
      .items([
        .text("first"),
        .localImage(imageURL),
        .text("second"),
      ])
    )

    #expect(turn.finalResponse == "first\n\n[local image: example.png]\n\nsecond")
    expectAgentMessageItem(turn.items, text: "first\n\n[local image: example.png]\n\nsecond")
    #expect(turn.usage == deterministicDefaultUsage())
  }

  @Test("Image-only input remains usable at the buffered boundary")
  func imageOnlyInputProducesBufferedSummary() async throws {
    let codex = Codex()
    let thread = startDeterministicThread(codex)
    let imageURL = URL(fileURLWithPath: "/tmp/screenshot.jpg")

    let turn = try await thread.run(.items([.localImage(imageURL)]))

    #expect(turn.finalResponse == "[local image: screenshot.jpg]")
    expectAgentMessageItem(turn.items, text: "[local image: screenshot.jpg]")
    #expect(turn.usage == deterministicDefaultUsage())
  }

}
private func collect<S: AsyncSequence>(
  _ stream: S
) async throws -> [S.Element] where S: Sendable {
  var values: [S.Element] = []

  for try await value in stream {
    values.append(value)
  }

  return values
}

private func expectCompletedAgentMessageEvent(_ event: ThreadEvent, text: String) {
  guard case .itemCompleted(let item) = event else {
    Issue.record("Expected itemCompleted event")
    return
  }

  expectAgentMessageItem(item, text: text)
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

private func expectTurnCompletedUsage(
  _ event: ThreadEvent,
  expected: Usage
) {
  guard case .turnCompleted(let usage) = event else {
    Issue.record("Expected turnCompleted event")
    return
  }

  #expect(usage == expected)
}

private func deterministicDefaultUsage() -> Usage {
  Usage(inputTokens: 0, cachedInputTokens: 0, outputTokens: 0)
}

private func startDeterministicThread(
  _ codex: Codex,
  options: ThreadOptions = .init()
) -> CodexThread {
  let thread = codex.startThread(options: options)
  configureDeterministicSuccess(thread)
  return thread
}

private func resumeDeterministicThread(
  _ codex: Codex,
  _ id: String,
  options: ThreadOptions = .init()
) -> CodexThread {
  let thread = codex.resumeThread(id, options: options)
  configureDeterministicSuccess(thread)
  return thread
}

private func configureDeterministicSuccess(
  _ thread: CodexThread,
  usage: Usage = deterministicDefaultUsage()
) {
  _ = configureDeterministicExecutor(thread, usage: usage)
}

private actor StreamHandoff<Element: Sendable> {
  private var stored: Element?
  private var continuation: CheckedContinuation<Element, Never>?

  func publish(_ value: Element) {
    if let continuation {
      self.continuation = nil
      continuation.resume(returning: value)
    } else {
      stored = value
    }
  }

  func wait() async -> Element {
    if let stored {
      self.stored = nil
      return stored
    }

    return await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }
}

private actor OneShotSignal {
  private var isSignaled = false
  private var continuation: CheckedContinuation<Void, Never>?

  func signal() {
    guard !isSignaled else {
      return
    }

    isSignaled = true
    continuation?.resume()
    continuation = nil
  }

  func wait() async {
    if isSignaled {
      return
    }

    await withCheckedContinuation { continuation in
      if isSignaled {
        continuation.resume()
        return
      }

      self.continuation = continuation
    }
  }
}
