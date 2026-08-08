import CodexExec
import Foundation

/// Stateful SDK thread wrapper that maps SDK turns onto upstream exec sessions.
public final class CodexThread: @unchecked Sendable {
  /// The resolved upstream session identifier, if the thread has one.
  public var id: String? {
    state.currentID
  }

  let threadOptions: ThreadOptions
  let clientOptions: CodexOptions
  package var executorOverride: (any CodexThreadExecuting)?
  package var executionClientOverride: CodexExecClient?
  let state: ThreadState

  init(id: String?, threadOptions: ThreadOptions, clientOptions: CodexOptions) {
    self.threadOptions = threadOptions
    self.clientOptions = clientOptions
    self.state = ThreadState(id: id)
  }

  /// Runs a turn and buffers the event stream into a `Turn` convenience value.
  public func run(_ input: Input, options: TurnOptions = .init()) async throws -> Turn {
    try Task.checkCancellation()
    let streamedTurn = try await runStreamed(input, options: options)
    var accumulator = BufferedTurnAccumulator()

    for try await event in streamedTurn.events {
      try accumulator.consume(event)
      executorOverride?.didConsume(event)
      if accumulator.didComplete {
        return accumulator.completedTurn()
      }
    }
    if Task.isCancelled && !accumulator.didComplete {
      throw CancellationError()
    }
    return accumulator.completedTurn()
  }

  /// Runs a turn and returns the ordered SDK event stream without buffering it.
  public func runStreamed(
    _ input: Input,
    options: TurnOptions = .init()
  ) async throws -> StreamedTurn {
    try Task.checkCancellation()
    let callerCancellationProbe = CodexCallerCancellationProbe(
      task: withUnsafeCurrentTask { $0 }
    )

    return StreamedTurn(
      events: try makeEventStream(
        input: input,
        options: options,
        callerCancellationProbe: callerCancellationProbe
      ))
  }

  package func preparedTurnContext(
    turnOptions: TurnOptions = .init()
  ) -> CodexThreadExecutionContext {
    var config = clientOptions.config

    if let model = threadOptions.model {
      config["model"] = .string(model)
    }
    if let sandboxMode = threadOptions.sandboxMode {
      config["sandbox_mode"] = .string(sandboxMode)
    }
    if let modelReasoningEffort = threadOptions.modelReasoningEffort {
      config["model_reasoning_effort"] = .string(modelReasoningEffort)
    }
    if let networkAccessEnabled = threadOptions.networkAccessEnabled {
      config["sandbox_workspace_write"] = mergedObject(
        existing: config["sandbox_workspace_write"],
        updates: ["network_access": .bool(networkAccessEnabled)]
      )
    }
    if let webSearchMode = resolvedWebSearchMode() {
      config["web_search"] = .string(webSearchMode)
    }
    if let approvalPolicy = threadOptions.approvalPolicy {
      config["approval_policy"] = .string(approvalPolicy)
    }

    return CodexThreadExecutionContext(
      codexPathOverride: clientOptions.codexPathOverride,
      baseURL: clientOptions.baseURL,
      apiKey: clientOptions.apiKey,
      config: config,
      environment: clientOptions.environment,
      model: threadOptions.model,
      sandboxMode: threadOptions.sandboxMode,
      workingDirectory: threadOptions.workingDirectory,
      skipGitRepoCheck: threadOptions.skipGitRepoCheck,
      modelReasoningEffort: threadOptions.modelReasoningEffort,
      networkAccessEnabled: threadOptions.networkAccessEnabled,
      webSearchMode: resolvedWebSearchMode(),
      approvalPolicy: threadOptions.approvalPolicy,
      additionalDirectories: threadOptions.additionalDirectories,
      outputSchema: turnOptions.outputSchema
    )
  }

  private func resolvedWebSearchMode() -> String? {
    threadOptions.webSearchMode
  }
}
