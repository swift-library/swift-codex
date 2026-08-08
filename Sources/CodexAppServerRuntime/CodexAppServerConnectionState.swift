import Foundation

package enum CodexAppServerConnectionStateError: Error, Equatable, Sendable {
  case closed
  case duplicatePendingResponse(id: CodexAppServerConnectionFoundation.RequestID)
  case duplicateServerRequest(id: CodexAppServerConnectionFoundation.RequestID)
  case serverRequestAlreadyCompleted(id: CodexAppServerConnectionFoundation.RequestID)
}

package actor CodexAppServerConnectionState {
  private var nextRequestID: Int64 = 1
  private var isClosed = false
  private var pending:
    [CodexAppServerConnectionFoundation.RequestID: CodexAppServerPendingResponse] = [:]
  private var cancelledPendingResponses: Set<CodexAppServerConnectionFoundation.RequestID> = []
  private var activeServerRequests: Set<CodexAppServerConnectionFoundation.RequestID> = []

  package init() {}

  package func allocateRequestID(
    _ explicitID: CodexAppServerConnectionFoundation.RequestID?
  ) throws -> CodexAppServerConnectionFoundation.RequestID {
    if isClosed {
      throw CodexAppServerConnectionStateError.closed
    }

    if let explicitID {
      return explicitID
    }

    let id = CodexAppServerConnectionFoundation.RequestID.integer(nextRequestID)
    nextRequestID += 1
    return id
  }

  package func addPending(
    id: CodexAppServerConnectionFoundation.RequestID,
    pendingResponse: CodexAppServerPendingResponse
  ) throws {
    if isClosed {
      throw CodexAppServerConnectionStateError.closed
    }

    guard pending[id] == nil else {
      throw CodexAppServerConnectionStateError.duplicatePendingResponse(id: id)
    }

    pending[id] = pendingResponse
  }

  package func takePending(
    id: CodexAppServerConnectionFoundation.RequestID
  ) -> CodexAppServerPendingResponse? {
    pending.removeValue(forKey: id)
  }

  package func removePending(id: CodexAppServerConnectionFoundation.RequestID) {
    pending.removeValue(forKey: id)
  }

  package func cancelPending(id: CodexAppServerConnectionFoundation.RequestID, error: Error) {
    guard let pendingResponse = pending.removeValue(forKey: id) else {
      return
    }

    cancelledPendingResponses.insert(id)
    pendingResponse.fail(error)
  }

  package func consumeCancelledResponse(
    id: CodexAppServerConnectionFoundation.RequestID
  ) -> Bool {
    cancelledPendingResponses.remove(id) != nil
  }

  package func addServerRequest(id: CodexAppServerConnectionFoundation.RequestID) throws {
    if activeServerRequests.contains(id) {
      throw CodexAppServerConnectionStateError.duplicateServerRequest(id: id)
    }

    activeServerRequests.insert(id)
  }

  package func completeServerRequest(id: CodexAppServerConnectionFoundation.RequestID) throws {
    guard activeServerRequests.remove(id) != nil else {
      throw CodexAppServerConnectionStateError.serverRequestAlreadyCompleted(id: id)
    }
  }

  package func close(error: Error) -> [CodexAppServerPendingResponse] {
    if isClosed {
      return []
    }

    isClosed = true
    activeServerRequests.removeAll()
    let pendingResponses = Array(pending.values)
    pending.removeAll()
    return pendingResponses
  }
}

package final class CodexAppServerPendingResponse: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation:
    CheckedContinuation<CodexAppServerConnectionFoundation.JSONValue, Error>?
  private var result: Result<CodexAppServerConnectionFoundation.JSONValue, Error>?

  package init() {}

  package func wait() async throws -> CodexAppServerConnectionFoundation.JSONValue {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      if let result {
        lock.unlock()
        continuation.resume(with: result)
      } else {
        self.continuation = continuation
        lock.unlock()
      }
    }
  }

  package func succeed(_ value: CodexAppServerConnectionFoundation.JSONValue) {
    resume(.success(value))
  }

  package func fail(_ error: Error) {
    resume(.failure(error))
  }

  private func resume(
    _ result: Result<CodexAppServerConnectionFoundation.JSONValue, Error>
  ) {
    lock.lock()
    if let continuation {
      self.continuation = nil
      lock.unlock()
      continuation.resume(with: result)
    } else {
      self.result = result
      lock.unlock()
    }
  }
}
