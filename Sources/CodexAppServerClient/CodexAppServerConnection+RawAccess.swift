import CodexAppServerProtocol

extension CodexAppServerConnection {
  /// Sends a raw JSON-RPC request for diagnostics or upstream drift handling.
  /// Prefer generated typed methods whenever the method is already modeled by
  /// this target.
  public func sendRawRequest(
    method: String
  ) async throws -> CodexAppServerProtocol.Stable.JSONValue {
    try Self.validateRawMethod(method)
    return try await _sendStableRequest(
      method: method,
      params: nil,
      responseType: CodexAppServerProtocol.Stable.JSONValue.self,
      id: nil
    )
  }

  /// Sends a raw JSON-RPC request with encodable params for diagnostics or
  /// unsupported-yet-generated upstream methods.
  public func sendRawRequest<Params: Encodable & Sendable>(
    method: String,
    params: Params
  ) async throws -> CodexAppServerProtocol.Stable.JSONValue {
    try Self.validateRawMethod(method)
    return try await _sendStableRequest(
      method: method,
      params: Self.encodeStableJSONValue(params),
      responseType: CodexAppServerProtocol.Stable.JSONValue.self,
      id: nil
    )
  }

  /// Sends a raw JSON-RPC notification for diagnostics or upstream drift
  /// handling. Prefer generated typed notification/request APIs when present.
  public func sendRawNotification(method: String) async throws {
    try Self.validateRawMethod(method)
    let notification = CodexAppServerProtocol.Stable.JSONRPCNotification(method: method)
    try await sendStableMessage(notification)
  }

  /// Sends a raw JSON-RPC notification with encodable params for diagnostics or
  /// unsupported-yet-generated upstream notification methods.
  public func sendRawNotification<Params: Encodable & Sendable>(
    method: String,
    params: Params
  ) async throws {
    try Self.validateRawMethod(method)
    let notification = CodexAppServerProtocol.Stable.JSONRPCNotification(
      method: method,
      params: try Self.encodeStableJSONValue(params)
    )
    try await sendStableMessage(notification)
  }

  private static func validateRawMethod(_ method: String) throws {
    let trimmedMethod = method.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedMethod.isEmpty, trimmedMethod == method else {
      throw CodexAppServerClientError.invalidRawMethod(method)
    }

    guard !rawMethodDenyList.contains(method) else {
      throw CodexAppServerClientError.rawMethodNotAllowed(method)
    }
  }

}
