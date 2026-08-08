import Foundation

@testable import Codex

enum DeterministicCodexFailureMode: Sendable {
  case turnFailed(ThreadError)
  case streamError(ThreadError)
}

final class DeterministicCodexThreadExecutor: CodexThreadExecuting, @unchecked Sendable {
  private let lock = NSLock()
  private var _interEventDelayNanoseconds: UInt64 = 0
  private var _postTerminalSuccessDelayNanoseconds: UInt64 = 0
  private var _onTerminalSuccessObserved: (@Sendable () -> Void)?
  private var _usage = Usage(inputTokens: 0, cachedInputTokens: 0, outputTokens: 0)
  private var _failureMode: DeterministicCodexFailureMode?

  var interEventDelayNanoseconds: UInt64 {
    get { withLock { _interEventDelayNanoseconds } }
    set { withLock { _interEventDelayNanoseconds = newValue } }
  }

  var postTerminalSuccessDelayNanoseconds: UInt64 {
    get { withLock { _postTerminalSuccessDelayNanoseconds } }
    set { withLock { _postTerminalSuccessDelayNanoseconds = newValue } }
  }

  var onTerminalSuccessObserved: (@Sendable () -> Void)? {
    get { withLock { _onTerminalSuccessObserved } }
    set { withLock { _onTerminalSuccessObserved = newValue } }
  }

  var usage: Usage {
    get { withLock { _usage } }
    set { withLock { _usage = newValue } }
  }

  var failureMode: DeterministicCodexFailureMode? {
    get { withLock { _failureMode } }
    set { withLock { _failureMode = newValue } }
  }

  func eventStream(
    for request: CodexThreadExecutionRequest
  ) throws -> AsyncThrowingStream<ThreadEvent, Error> {
    let settings = snapshot()
    let events = makeEvents(request: request, settings: settings)

    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          for event in events {
            try Task.checkCancellation()
            if settings.interEventDelayNanoseconds > 0 {
              try await Task.sleep(nanoseconds: settings.interEventDelayNanoseconds)
            } else {
              await Task.yield()
            }
            continuation.yield(event)

            if case .error(let error) = event {
              continuation.finish(throwing: error)
              return
            }
          }

          if case .some(.turnCompleted(usage: _)) = events.last {
            if settings.postTerminalSuccessDelayNanoseconds > 0 {
              do {
                try await Task.sleep(
                  nanoseconds: settings.postTerminalSuccessDelayNanoseconds)
              } catch is CancellationError {
                continuation.finish()
                return
              }
            }
          }
          continuation.finish()
        } catch is CancellationError {
          continuation.finish(throwing: CancellationError())
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func didConsume(_ event: ThreadEvent) {
    if case .turnCompleted = event {
      snapshot().onTerminalSuccessObserved?()
    }
  }

  private func makeEvents(
    request: CodexThreadExecutionRequest,
    settings: Settings
  ) -> [ThreadEvent] {
    var events: [ThreadEvent] = []
    if request.shouldEmitThreadStarted {
      events.append(.threadStarted(id: request.proposedThreadID))
    }
    events.append(.turnStarted)

    switch settings.failureMode {
    case .turnFailed(let error):
      events.append(.turnFailed(error))
      return events
    case .streamError(let error):
      events.append(.error(error))
      return events
    case nil:
      break
    }

    let response = displayText(for: request.input)
    if !response.isEmpty {
      events.append(
        .itemCompleted(
          .agentMessage(.init(id: "item_\(UUID().uuidString)", text: response))))
    }
    events.append(.turnCompleted(usage: settings.usage))
    return events
  }

  private func displayText(for input: Input) -> String {
    switch input {
    case .text(let text):
      return text
    case .items(let items):
      return items.map { item in
        switch item {
        case .text(let text):
          return text
        case .localImage(let url):
          return "[local image: \(url.lastPathComponent)]"
        }
      }.joined(separator: "\n\n")
    }
  }

  private func snapshot() -> Settings {
    withLock {
      Settings(
        interEventDelayNanoseconds: _interEventDelayNanoseconds,
        postTerminalSuccessDelayNanoseconds: _postTerminalSuccessDelayNanoseconds,
        onTerminalSuccessObserved: _onTerminalSuccessObserved,
        usage: _usage,
        failureMode: _failureMode
      )
    }
  }

  private func withLock<Value>(_ body: () -> Value) -> Value {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  private struct Settings: Sendable {
    let interEventDelayNanoseconds: UInt64
    let postTerminalSuccessDelayNanoseconds: UInt64
    let onTerminalSuccessObserved: (@Sendable () -> Void)?
    let usage: Usage
    let failureMode: DeterministicCodexFailureMode?
  }
}

func configureDeterministicExecutor(
  _ thread: CodexThread,
  usage: Usage = Usage(inputTokens: 0, cachedInputTokens: 0, outputTokens: 0)
) -> DeterministicCodexThreadExecutor {
  let executor = DeterministicCodexThreadExecutor()
  executor.usage = usage
  thread.executorOverride = executor
  return executor
}

func deterministicExecutor(for thread: CodexThread) -> DeterministicCodexThreadExecutor {
  guard let executor = thread.executorOverride as? DeterministicCodexThreadExecutor else {
    preconditionFailure("Thread is not configured with a deterministic test executor")
  }
  return executor
}
