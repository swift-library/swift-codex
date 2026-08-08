import CodexAppServerProtocol

public enum CodexAppServerClientError: Error, Equatable, Sendable {
  case closed
  case peerClosed
  case requestCancelled
  case malformedInbound(String)
  case malformedOutbound(String)
  case invalidRawMethod(String)
  case rawMethodNotAllowed(String)
  case jsonRPCError(code: Int64, message: String, data: CodexAppServerProtocol.Stable.JSONValue?)
  case unmatchedResponse(id: CodexAppServerProtocol.Stable.RequestId)
  case duplicateServerRequest(id: CodexAppServerProtocol.Stable.RequestId)
  case serverRequestAlreadyCompleted(id: CodexAppServerProtocol.Stable.RequestId)
  case responseDecodeFailure(String)
}
