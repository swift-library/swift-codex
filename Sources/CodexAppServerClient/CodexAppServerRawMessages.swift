import CodexAppServerProtocol
import Foundation

/// A notification's complete JSON envelope, including fields unknown to the pinned schema.
public struct CodexAppServerRawNotification: Equatable, Sendable {
  public let method: String
  public let params: CodexAppServerProtocol.Stable.JSONValue?
  public let payload: CodexAppServerProtocol.Stable.JSONValue
}

/// A server request owned by the connection that received it.
/// Resolve or reject the handle once through that connection.
public struct CodexAppServerRawServerRequest: Sendable {
  public let id: CodexAppServerProtocol.Stable.RequestId
  public let method: String
  public let params: CodexAppServerProtocol.Stable.JSONValue?
  public let payload: CodexAppServerProtocol.Stable.JSONValue
  let connectionID: UUID
  let requestToken: UUID
}

extension CodexAppServerConnection {
  /// Completes a raw server request without narrowing its response to a generated schema.
  public func resolveServerRequest<Response: Encodable & Sendable>(
    _ request: CodexAppServerRawServerRequest,
    with response: Response
  ) async throws {
    let result = try Self.encodeStableJSONValue(response)
    try await completeRawServerRequest(request)
    try await sendStableMessage(
      CodexAppServerProtocol.Stable.JSONRPCResponse(id: request.id, result: result))
  }

  /// Rejects a raw server request through the same once-only lifecycle as typed handles.
  public func rejectServerRequest(
    _ request: CodexAppServerRawServerRequest,
    code: Int64,
    message: String,
    data: CodexAppServerProtocol.Stable.JSONValue? = nil
  ) async throws {
    try await completeRawServerRequest(request)
    try await sendStableMessage(
      CodexAppServerProtocol.Stable.JSONRPCError(
        error: .init(code: code, data: data, message: message), id: request.id))
  }

  private func completeRawServerRequest(_ request: CodexAppServerRawServerRequest) async throws {
    guard request.connectionID == inboundChannels.connectionID else {
      throw CodexAppServerClientError.foreignServerRequest(id: request.id)
    }
    try await Self.mapRuntimeStateError {
      try await state.completeServerRequest(
        id: Self.runtimeRequestID(request.id), token: request.requestToken)
    }
  }
}
