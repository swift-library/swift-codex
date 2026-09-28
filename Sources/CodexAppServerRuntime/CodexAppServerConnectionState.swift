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
  private var retainedIdentifierBytes = 0
  private var pending:
    [CodexAppServerConnectionFoundation.RequestID: CodexAppServerPendingResponse] = [:]
  private var cancelledPendingResponses: Set<CodexAppServerConnectionFoundation.RequestID> = []
  private var activeServerRequests: [CodexAppServerConnectionFoundation.RequestID: UUID] = [:]

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

    guard pending[id] == nil, !cancelledPendingResponses.contains(id) else {
      throw CodexAppServerConnectionStateError.duplicatePendingResponse(id: id)
    }

    try reserveIdentifier(id)
    pending[id] = pendingResponse
  }

  package func takePending(
    id: CodexAppServerConnectionFoundation.RequestID
  ) -> CodexAppServerPendingResponse? {
    guard let response = pending.removeValue(forKey: id) else { return nil }
    retainedIdentifierBytes -= identifierBytes(id)
    return response
  }

  package func removePending(id: CodexAppServerConnectionFoundation.RequestID) {
    _ = takePending(id: id)
  }

  package func cancelPending(id: CodexAppServerConnectionFoundation.RequestID, error: Error) {
    guard let pendingResponse = pending.removeValue(forKey: id) else {
      return
    }

    // Cancellation transfers the reservation to its late-response tombstone.
    // Reusing this ID early could correlate an old reply with new work.
    cancelledPendingResponses.insert(id)
    pendingResponse.fail(error)
  }

  package func consumeCancelledResponse(
    id: CodexAppServerConnectionFoundation.RequestID
  ) -> Bool {
    guard cancelledPendingResponses.remove(id) != nil else { return false }
    retainedIdentifierBytes -= identifierBytes(id)
    return true
  }

  @discardableResult
  package func addServerRequest(id: CodexAppServerConnectionFoundation.RequestID) throws -> UUID {
    guard !isClosed else {
      throw CodexAppServerConnectionStateError.closed
    }
    if activeServerRequests[id] != nil {
      throw CodexAppServerConnectionStateError.duplicateServerRequest(id: id)
    }

    try reserveIdentifier(id)
    let token = UUID()
    activeServerRequests[id] = token
    return token
  }

  package func completeServerRequest(
    id: CodexAppServerConnectionFoundation.RequestID,
    token: UUID? = nil
  ) throws {
    guard let activeToken = activeServerRequests[id], token == nil || token == activeToken else {
      throw CodexAppServerConnectionStateError.serverRequestAlreadyCompleted(id: id)
    }
    activeServerRequests.removeValue(forKey: id)
    retainedIdentifierBytes -= identifierBytes(id)
  }

  /// Only the caller that closes admission receives the pending replies.
  package func close() -> [CodexAppServerPendingResponse]? {
    if isClosed {
      return nil
    }

    isClosed = true
    activeServerRequests.removeAll()
    cancelledPendingResponses.removeAll()
    let pendingResponses = Array(pending.values)
    pending.removeAll()
    retainedIdentifierBytes = 0
    return pendingResponses
  }

  private func reserveIdentifier(_ id: CodexAppServerConnectionFoundation.RequestID) throws {
    let count = pending.count + cancelledPendingResponses.count + activeServerRequests.count
    let bytes = identifierBytes(id)
    guard count < CodexAppServerBufferLimits.messages,
      bytes <= CodexAppServerBufferLimits.bytes - retainedIdentifierBytes
    else {
      throw CodexAppServerConnectionFoundation.FoundationError.bufferLimitExceeded(
        maximumMessages: CodexAppServerBufferLimits.messages,
        maximumBytes: CodexAppServerBufferLimits.bytes)
    }
    retainedIdentifierBytes += bytes
  }

  private func identifierBytes(_ id: CodexAppServerConnectionFoundation.RequestID) -> Int {
    switch id {
    case .integer: return MemoryLayout<Int64>.size
    case .string(let value): return value.utf8.count
    }
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
