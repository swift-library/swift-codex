import CodexAppServerProtocol

extension CodexAppServerConnection {
  func performInitialize(
    configuration: CodexAppServerClient.SessionConfiguration
  ) async throws -> CodexAppServerProtocol.Stable.InitializeResponse {
    let capabilities = CodexAppServerProtocol.Stable.InitializeCapabilities(
      experimentalApi: configuration.experimentalApi,
      optOutNotificationMethods: configuration.optOutNotificationMethods.isEmpty
        ? nil
        : configuration.optOutNotificationMethods
    )
    let params = CodexAppServerProtocol.Stable.InitializeParams(
      capabilities: capabilities,
      clientInfo: .init(
        name: configuration.clientInfo.name,
        title: configuration.clientInfo.title,
        version: configuration.clientInfo.version
      )
    )

    return try await sendStableRequest(
      method: "initialize",
      params: params,
      responseType: CodexAppServerProtocol.Stable.InitializeResponse.self
    )
  }

  func sendStableInitializedNotification() async throws {
    let notification = CodexAppServerProtocol.Stable.ClientNotification.initializednotification(
      .init(method: .initialized)
    )
    try await sendStableMessage(notification)
  }
}
