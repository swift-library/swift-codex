import Foundation

extension CodexExecClient {
  func makeTermination(
    operation: CodexExecOperation,
    launchKind: CodexExecLaunchKind,
    requestSemantics: CodexExecRequestSemantics,
    preparedLaunch: CodexExecPreparedLaunch,
    output: CodexExecProcessOutput,
    collectedStdoutLines: [String],
    decoder: CodexExecJSONLDecoder
  ) throws -> CodexExecTermination {
    let exitInterpretation: CodexExecExitInterpretation
    if let exitStatus = output.exitStatus {
      exitInterpretation = .exited(code: exitStatus)
    } else {
      exitInterpretation = .signaled(output.terminationSignal ?? 0)
    }

    let partialObservation = try partialObservation(
      for: launchKind,
      output: output,
      collectedStdoutLines: collectedStdoutLines,
      decoder: decoder
    )

    if let postLaunchError = postLaunchError(
      for: launchKind,
      processOutput: output,
      partialObservation: partialObservation
    ) {
      throw postLaunchError
    }

    if requiresCompletedTurn(for: launchKind), !hasCompletedTurn(partialObservation) {
      throw CodexExecError.interrupted(partialObservation: partialObservation)
    }

    if let outputLastMessageFile = requestSemantics.outputLastMessageFile {
      try verifyOutputLastMessageFile(
        at: outputLastMessageFile,
        expectedContents: partialObservation.finalMessageText ?? "",
        partialObservation: partialObservation
      )
    }

    return CodexExecTermination(
      operation: operation,
      effectiveWorkingDirectory: preparedLaunch.workingDirectory,
      exitInterpretation: exitInterpretation,
      capturedStderrText: partialObservation.stderrText
    )
  }

  func partialObservation(
    for kind: CodexExecLaunchKind,
    output: CodexExecProcessOutput,
    collectedStdoutLines: [String],
    decoder: CodexExecJSONLDecoder
  ) throws -> CodexExecPartialObservation {
    let stderrText = String(decoding: output.standardError, as: UTF8.self)

    switch outputMode(for: kind) {
    case .humanReadable:
      let stdoutText = String(decoding: output.standardOutput, as: UTF8.self)
      return CodexExecPartialObservation(
        stderrText: stderrText,
        finalMessageText: stdoutText.isEmpty ? nil : stdoutText,
        events: [],
        resolvedSessionID: nil
      )
    case .jsonl:
      var events: [CodexExecEvent] = []
      var finalMessageText: String?
      var resolvedSessionID: String?

      for line in collectedStdoutLines {
        let event: CodexExecEvent
        do {
          event = try decoder.decodeLine(line)
        } catch let error as CodexExecError {
          if case .malformedJSONL(let line, _) = error {
            throw CodexExecError.malformedJSONL(
              line: line,
              partialObservation: CodexExecPartialObservation(
                stderrText: stderrText,
                finalMessageText: finalMessageText,
                events: events,
                resolvedSessionID: resolvedSessionID
              )
            )
          }
          throw error
        }

        events.append(event)

        if resolvedSessionID == nil, case .threadStarted(let id) = event {
          resolvedSessionID = id
        }

        if case .itemStarted(let item) = event,
          item.kind == .agentMessage,
          let text = item.text
        {
          finalMessageText = text
        }
        if case .itemUpdated(let item) = event,
          item.kind == .agentMessage,
          let text = item.text
        {
          finalMessageText = text
        }
        if case .itemCompleted(let item) = event,
          item.kind == .agentMessage,
          let text = item.text
        {
          finalMessageText = text
        }
      }

      return CodexExecPartialObservation(
        stderrText: stderrText,
        finalMessageText: finalMessageText,
        events: events,
        resolvedSessionID: resolvedSessionID
      )
    }
  }

  func postLaunchError(
    for kind: CodexExecLaunchKind,
    processOutput: CodexExecProcessOutput,
    partialObservation: CodexExecPartialObservation
  ) -> CodexExecError? {
    if processOutput.terminationSignal != nil {
      return .interrupted(partialObservation: partialObservation)
    }

    guard let exitStatus = processOutput.exitStatus, exitStatus != 0 else {
      return nil
    }

    if let resumeSelector = resumeSelector(for: kind),
      isResumeTargetNotFound(stderrText: partialObservation.stderrText)
    {
      return .resumeTargetNotFound(
        selector: resumeSelector,
        partialObservation: partialObservation
      )
    }

    if isInterrupted(partialObservation: partialObservation) {
      return .interrupted(partialObservation: partialObservation)
    }

    return .nonZeroExit(
      code: exitStatus,
      stderr: partialObservation.stderrText,
      partialObservation: partialObservation
    )
  }

  func requiresCompletedTurn(for kind: CodexExecLaunchKind) -> Bool {
    outputMode(for: kind) == .jsonl
  }

  func hasCompletedTurn(_ partialObservation: CodexExecPartialObservation) -> Bool {
    partialObservation.events.contains { event in
      if case .turnCompleted = event {
        return true
      }

      return false
    }
  }

  func resumeSelector(for kind: CodexExecLaunchKind) -> CodexExecResumeSelector? {
    guard case .resume(let request) = kind else {
      return nil
    }

    return request.selector
  }

  func isResumeTargetNotFound(stderrText: String) -> Bool {
    let normalized = stderrText.lowercased()
    return normalized.contains("thread not found")
      || normalized.contains("session not found")
      || normalized.contains("resume target not found")
  }

  func isInterrupted(partialObservation: CodexExecPartialObservation) -> Bool {
    if partialObservation.stderrText.localizedCaseInsensitiveContains("interrupted") {
      return true
    }

    return partialObservation.events.contains { event in
      switch event {
      case .turnFailed(let error):
        return error.message.localizedCaseInsensitiveContains("interrupted")
      case .error(let error):
        return error.message.localizedCaseInsensitiveContains("interrupted")
      default:
        return false
      }
    }
  }

  func verifyOutputLastMessageFile(
    at path: URL,
    expectedContents: String,
    partialObservation: CodexExecPartialObservation
  ) throws {
    let fileContents: String
    do {
      fileContents = try String(contentsOf: path, encoding: .utf8)
    } catch {
      throw CodexExecError.outputFileFailure(
        path: path,
        description: "Failed to read output-last-message file: \(error.localizedDescription)",
        partialObservation: partialObservation
      )
    }

    guard fileContents == expectedContents else {
      throw CodexExecError.outputFileFailure(
        path: path,
        description: "Output-last-message file contents did not match the final message.",
        partialObservation: partialObservation
      )
    }
  }

  func outputMode(for kind: CodexExecLaunchKind) -> CodexExecOutputMode {
    switch kind {
    case .run(let request):
      return request.outputMode
    case .resume(let request):
      return request.outputMode
    }
  }

  func cancelledError(
    for kind: CodexExecLaunchKind,
    launchError: CodexExecLaunchCancelled,
    collectedStdoutLines: [String] = [],
    decoder: CodexExecJSONLDecoder = .init()
  ) -> CodexExecError {
    guard let processOutput = launchError.processOutput else {
      return .cancelled(partialObservation: nil)
    }

    do {
      let partialObservation = try partialObservation(
        for: kind,
        output: processOutput,
        collectedStdoutLines: collectedStdoutLines,
        decoder: decoder
      )
      return .cancelled(partialObservation: partialObservation)
    } catch let error as CodexExecError {
      switch error {
      case .malformedJSONL(_, let partialObservation):
        return .cancelled(partialObservation: partialObservation)
      default:
        return .cancelled(partialObservation: nil)
      }
    } catch {
      return .cancelled(partialObservation: nil)
    }
  }
}
