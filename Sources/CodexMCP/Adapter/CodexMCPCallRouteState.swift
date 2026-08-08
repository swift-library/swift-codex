import Foundation

internal actor CodexMCPServerMessageStreamController {
  private var continuation: AsyncStream<CodexMCPServerMessage>.Continuation?
  private var bufferedMessages: [CodexMCPServerMessage] = []
  private var isFinished = false

  static func makeStream() -> (
    AsyncStream<CodexMCPServerMessage>, CodexMCPServerMessageStreamController
  ) {
    let controller = CodexMCPServerMessageStreamController()
    let stream = AsyncStream<CodexMCPServerMessage> { continuation in
      Task {
        await controller.attach(continuation)
      }
    }

    return (stream, controller)
  }

  func attach(_ continuation: AsyncStream<CodexMCPServerMessage>.Continuation) {
    self.continuation = continuation
    for message in bufferedMessages {
      continuation.yield(message)
    }
    bufferedMessages.removeAll(keepingCapacity: false)

    if isFinished {
      continuation.finish()
    }
  }

  func yield(_ message: CodexMCPServerMessage) {
    if let continuation {
      continuation.yield(message)
      return
    }

    bufferedMessages.append(message)
  }

  func finish() {
    isFinished = true
    continuation?.finish()
  }
}

internal actor CodexMCPApprovalRequestStreamController {
  private var continuation: AsyncStream<CodexMCPApprovalRequest>.Continuation?
  private var bufferedRequests: [CodexMCPApprovalRequest] = []
  private var isFinished = false

  static func makeStream() -> (
    AsyncStream<CodexMCPApprovalRequest>, CodexMCPApprovalRequestStreamController
  ) {
    let controller = CodexMCPApprovalRequestStreamController()
    let stream = AsyncStream<CodexMCPApprovalRequest> { continuation in
      Task {
        await controller.attach(continuation)
      }
    }

    return (stream, controller)
  }

  func attach(_ continuation: AsyncStream<CodexMCPApprovalRequest>.Continuation) {
    self.continuation = continuation
    for request in bufferedRequests {
      continuation.yield(request)
    }
    bufferedRequests.removeAll(keepingCapacity: false)

    if isFinished {
      continuation.finish()
    }
  }

  func yield(_ request: CodexMCPApprovalRequest) {
    if let continuation {
      continuation.yield(request)
      return
    }

    bufferedRequests.append(request)
  }

  func finish() {
    isFinished = true
    continuation?.finish()
  }
}

internal actor CodexMCPApprovalState {
  private var pendingRequestIDs: Set<CodexMCPRequestID> = []
  private var isClosed = false

  func register(_ requestID: CodexMCPRequestID) {
    guard !isClosed else {
      return
    }

    pendingRequestIDs.insert(requestID)
  }

  func consume(_ requestID: CodexMCPRequestID) -> Bool {
    guard !isClosed else {
      return false
    }

    return pendingRequestIDs.remove(requestID) != nil
  }

  func close() {
    isClosed = true
    pendingRequestIDs.removeAll(keepingCapacity: false)
  }
}

internal actor CodexMCPRequestCancellationState {
  private var activeRequestIDs: Set<CodexMCPRequestID> = []
  private var cancellationRequestedIDs: Set<CodexMCPRequestID> = []

  func register(_ requestID: CodexMCPRequestID) {
    activeRequestIDs.insert(requestID)
  }

  func beginCancellation(for requestID: CodexMCPRequestID) -> Bool {
    guard activeRequestIDs.contains(requestID) else {
      return false
    }

    guard !cancellationRequestedIDs.contains(requestID) else {
      return false
    }

    cancellationRequestedIDs.insert(requestID)
    return true
  }

  func rollbackCancellation(for requestID: CodexMCPRequestID) {
    cancellationRequestedIDs.remove(requestID)
  }

  func complete(_ requestID: CodexMCPRequestID) {
    activeRequestIDs.remove(requestID)
    cancellationRequestedIDs.remove(requestID)
  }
}
