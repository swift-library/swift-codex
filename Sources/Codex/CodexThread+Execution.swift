import CodexExec
import Foundation

extension CodexThread {
  func makeEventStream(
    input: Input,
    options: TurnOptions,
    callerCancellationProbe: CodexCallerCancellationProbe?
  ) throws -> AsyncThrowingStream<ThreadEvent, Error> {
    let context = preparedTurnContext(turnOptions: options)
    let normalizedInput = normalizeInput(input)
    let baseStream: AsyncThrowingStream<ThreadEvent, Error>

    if let executorOverride {
      let resolution = state.prepareIDForTurn()
      baseStream = try executorOverride.eventStream(
        for: .init(
          proposedThreadID: resolution.id,
          shouldEmitThreadStarted: resolution.wasResolvedNow,
          input: input,
          normalizedInput: normalizedInput,
          context: context
        )
      )
    } else {
      baseStream = try makeLiveEventStream(
        normalizedInput: normalizedInput,
        context: context
      )
    }

    return observingEventStream(
      baseStream,
      callerCancellationProbe: callerCancellationProbe
    )
  }

  private func observingEventStream(
    _ baseStream: AsyncThrowingStream<ThreadEvent, Error>,
    callerCancellationProbe: CodexCallerCancellationProbe?
  ) -> AsyncThrowingStream<ThreadEvent, Error> {
    AsyncThrowingStream { continuation in
      let emissionTask = Task {
        do {
          for try await event in baseStream {
            try self.throwIfObservedTaskCancelled(callerCancellationProbe)
            self.observeThreadIdentity(from: event)
            continuation.yield(event)

            if case .error(let error) = event {
              continuation.finish(throwing: error)
              return
            }
          }
          continuation.finish()
        } catch is CancellationError {
          continuation.finish(throwing: CancellationError())
        } catch {
          continuation.finish(throwing: error)
        }
      }

      continuation.onTermination = { _ in
        emissionTask.cancel()
      }
    }
  }

  private func makeLiveEventStream(
    normalizedInput: NormalizedInput,
    context: CodexThreadExecutionContext
  ) throws -> AsyncThrowingStream<ThreadEvent, Error> {
    let resumedThreadID = state.currentID

    return AsyncThrowingStream { continuation in
      let emissionTask = Task {
        let schemaFile = try CodexOutputSchemaFile(outputSchema: context.outputSchema)
        defer { schemaFile.cleanup() }
        let client = self.executionClient(context: context)
        let handle = try await self.executionHandle(
          normalizedInput: normalizedInput,
          context: context,
          resumedThreadID: resumedThreadID,
          schemaPath: schemaFile.schemaPath,
          client: client
        )
        let decodedEvents = CodexExecJSONLDecoder().decode(handle.stdoutLines)

        do {
          for try await event in decodedEvents {
            continuation.yield(event)
          }

          _ = try await handle.waitForTermination()
          continuation.finish()
        } catch is CancellationError {
          continuation.finish(throwing: CancellationError())
        } catch let error as ThreadError {
          continuation.finish(throwing: error)
        } catch let error as CodexExecError {
          continuation.finish(throwing: self.streamFailure(from: error))
        } catch {
          continuation.finish(throwing: error)
        }
      }

      continuation.onTermination = { _ in
        emissionTask.cancel()
      }
    }
  }

  func normalizeInput(_ input: Input) -> NormalizedInput {
    switch input {
    case .text(let text):
      return NormalizedInput(
        prompt: text,
        images: []
      )

    case .items(let items):
      var promptParts: [String] = []
      var images: [URL] = []

      for item in items {
        switch item {
        case .text(let text):
          promptParts.append(text)

        case .localImage(let url):
          images.append(url)
        }
      }

      return NormalizedInput(
        prompt: promptParts.joined(separator: "\n\n"),
        images: images
      )
    }
  }

  private func throwIfObservedTaskCancelled(
    _ observedTask: CodexCallerCancellationProbe?
  ) throws {
    if observedTask?.isCancelled == true {
      throw CancellationError()
    }
  }

  func observeThreadIdentity(from event: ThreadEvent) {
    guard case .threadStarted(let id) = event else {
      return
    }

    state.resolveFromThreadStarted(id)
  }

  private func executionClient(
    context: CodexThreadExecutionContext
  ) -> CodexExecClient {
    if let executionClientOverride {
      return executionClientOverride
    }

    return CodexExecClient(
      configuration: CodexExecLaunchConfiguration(
        executableURL: clientOptions.codexPathOverride ?? context.codexPathOverride,
        environmentOverride: context.environment,
        apiKey: context.apiKey
      )
    )
  }

  private func executionHandle(
    normalizedInput: NormalizedInput,
    context: CodexThreadExecutionContext,
    resumedThreadID: String?,
    schemaPath: String?,
    client: CodexExecClient
  ) async throws -> CodexExecProcessHandle {
    let options = CodexExecRequestOptions(
      images: normalizedInput.images,
      additionalWritableDirectories: context.additionalDirectories,
      approvalMode: context.approvalPolicy,
      searchEnabled: context.webSearchMode == "live" ? true : nil,
      model: context.model,
      workingDirectory: context.workingDirectory,
      sandboxMode: context.sandboxMode,
      skipGitRepoCheck: context.skipGitRepoCheck,
      configOverrides: try execConfigOverrides(context)
    )
    let outputSchemaFile = schemaPath.map { URL(fileURLWithPath: $0) }
    let promptInput = CodexExecPromptInput.text(normalizedInput.prompt)

    if let resumedThreadID {
      return try await client.resume(
        CodexExecResumeRequest(
          selector: .sessionID(resumedThreadID),
          promptInput: promptInput,
          outputMode: .jsonl,
          options: options,
          outputSchemaFile: outputSchemaFile
        )
      )
    }

    return try await client.run(
      CodexExecRunRequest(
        promptInput: promptInput,
        outputMode: .jsonl,
        options: options,
        outputSchemaFile: outputSchemaFile
      )
    )
  }

  private func execConfigOverrides(
    _ context: CodexThreadExecutionContext
  ) throws -> [String] {
    var configOverrides = try serializedConfigOverrides(context.config)

    if let baseURL = context.baseURL {
      configOverrides.append(
        "openai_base_url=\(try tomlValue(.string(baseURL.absoluteString), path: "openai_base_url"))"
      )
    }

    return configOverrides
  }

  private func streamFailure(from error: CodexExecError) -> Error {
    switch error {
    case .cancelled:
      return CancellationError()
    case .invalidInvocation(let description),
      .launchFailure(let description):
      return CodexProcessError(message: description)
    case .resumeTargetNotFound(_, let partialObservation):
      return CodexProcessError(
        message: partialObservation?.stderrText ?? "Resume target not found"
      )
    case .nonZeroExit(_, let stderr, let partialObservation):
      return CodexProcessError(
        message: partialObservation?.finalMessageText ?? stderr
      )
    case .malformedJSONL(let line, _):
      return CodexProcessError(message: "Failed to decode Codex JSONL line: \(line)")
    case .interrupted(let partialObservation):
      return CodexProcessError(
        message: partialObservation?.stderrText.isEmpty == false
          ? partialObservation!.stderrText
          : "Codex exec was interrupted"
      )
    case .outputFileFailure(_, let description, _):
      return CodexProcessError(message: description)
    }
  }

}
