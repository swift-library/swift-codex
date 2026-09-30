import CodexAppServerProtocol

extension CodexAppServerConnection {
  /// Starts a thread with the adopted experimental request additions.
  ///
  /// `thread/start` has a stable response contract, while capabilities such as
  /// dynamic host tools currently exist only on the experimental request
  /// parameters. The connection must have been initialized with
  /// `experimentalApi: true` before this overload is used.
  public func threadStart(
    _ params: CodexAppServerProtocol.Experimental.ThreadStartParams
  ) async throws -> CodexAppServerProtocol.Stable.ThreadStartResponse {
    try await sendStableRequest(
      method: "thread/start",
      params: params,
      responseType: CodexAppServerProtocol.Stable.ThreadStartResponse.self
    )
  }

  /// Starts a turn with the adopted experimental request additions.
  ///
  /// `turn/start` has a stable response contract, while options such as the
  /// collaboration mode currently exist only on the experimental request
  /// parameters. The connection must have been initialized with
  /// `experimentalApi: true` before this overload is used.
  public func turnStart(
    _ params: CodexAppServerProtocol.Experimental.TurnStartParams
  ) async throws -> CodexAppServerProtocol.Stable.TurnStartResponse {
    try await sendStableRequest(
      method: "turn/start",
      params: params,
      responseType: CodexAppServerProtocol.Stable.TurnStartResponse.self
    )
  }
}
