import CodexAppServerProtocol
import CodexAppServerRuntime
import Foundation

/// A running App Server connection with generated request methods and inbound streams.
public final class CodexAppServerConnection: @unchecked Sendable {
  /// All stable server notifications in wire order.
  public let notifications:
    AsyncThrowingStream<CodexAppServerProtocol.Stable.ServerNotification, Error>

  /// Typed server requests that require a client response.
  public let typedServerRequests: AsyncThrowingStream<CodexAppServerTypedServerRequest, Error>

  /// Complete notifications in wire order when the session selects raw inbound messages.
  public let rawNotifications: AsyncThrowingStream<CodexAppServerRawNotification, Error>

  /// Complete server requests when the session selects raw inbound messages.
  public let rawServerRequests: AsyncThrowingStream<CodexAppServerRawServerRequest, Error>

  let transport: any CodexAppServerMessageTransport
  let state: CodexAppServerConnectionState
  let inboundChannels: CodexAppServerInboundChannels
  private let readTask: Task<Void, Never>

  init(
    transport: any CodexAppServerMessageTransport,
    inboundMessageMode: CodexAppServerClient.InboundMessageMode = .typed
  ) {
    let inboundChannels = CodexAppServerInboundChannels(mode: inboundMessageMode)
    let state = CodexAppServerConnectionState()

    self.transport = transport
    self.state = state
    self.inboundChannels = inboundChannels
    self.notifications = inboundChannels.notifications.stream
    self.typedServerRequests = inboundChannels.typedServerRequests.stream
    self.rawNotifications = inboundChannels.rawNotifications.stream
    self.rawServerRequests = inboundChannels.rawServerRequests.stream
    self.readTask = Task {
      await Self.consumeInboundMessages(
        from: transport,
        state: state,
        channels: inboundChannels
      )
    }
  }

  /// Closes the transport and finishes every pending request and inbound stream once.
  public func close() async {
    readTask.cancel()
    let pending = await state.close(error: CodexAppServerClientError.closed)
    await transport.close()
    for pendingResponse in pending {
      pendingResponse.fail(CodexAppServerClientError.closed)
    }
    inboundChannels.finish()
  }
}

struct CodexAppServerInboundChannels: Sendable {
  let mode: CodexAppServerClient.InboundMessageMode
  let connectionID = UUID()
  let notifications =
    CodexAppServerAsyncThrowingChannel<CodexAppServerProtocol.Stable.ServerNotification>()
  let typedServerRequests =
    CodexAppServerAsyncThrowingChannel<CodexAppServerTypedServerRequest>()
  let rawNotifications = CodexAppServerAsyncThrowingChannel<CodexAppServerRawNotification>()
  let rawServerRequests = CodexAppServerAsyncThrowingChannel<CodexAppServerRawServerRequest>()

  init(mode: CodexAppServerClient.InboundMessageMode) {
    self.mode = mode
    // Inactive streams terminate immediately; they never buffer unconsumed copies.
    switch mode {
    case .typed:
      rawNotifications.finish()
      rawServerRequests.finish()
    case .raw:
      notifications.finish()
      typedServerRequests.finish()
    }
  }

  func finish(throwing error: (any Error)? = nil) {
    if let error {
      notifications.finish(throwing: error)
      typedServerRequests.finish(throwing: error)
      rawNotifications.finish(throwing: error)
      rawServerRequests.finish(throwing: error)
    } else {
      notifications.finish()
      typedServerRequests.finish()
      rawNotifications.finish()
      rawServerRequests.finish()
    }
  }
}
