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

  /// Value-free compatibility observations in typed mode. At most the newest 64 are retained.
  /// Dropping an older observation does not drop protocol messages or responses.
  public let unhandledInboundMessages:
    AsyncThrowingStream<CodexAppServerUnhandledInboundMessage, Error>

  /// Complete notifications in wire order when the session selects raw inbound messages.
  public let rawNotifications: AsyncThrowingStream<CodexAppServerRawNotification, Error>

  /// Complete server requests when the session selects raw inbound messages.
  public let rawServerRequests: AsyncThrowingStream<CodexAppServerRawServerRequest, Error>

  /// Notifications and server requests in one wire-ordered stream in rawOrdered mode.
  /// Consume each message before admitting work that depends on later messages.
  public let rawInboundMessages: AsyncThrowingStream<CodexAppServerRawInboundMessage, Error>

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
    self.unhandledInboundMessages = inboundChannels.unhandled.stream
    self.notifications = inboundChannels.notifications.stream
    self.typedServerRequests = inboundChannels.typedServerRequests.stream
    self.rawNotifications = inboundChannels.rawNotifications.stream
    self.rawServerRequests = inboundChannels.rawServerRequests.stream
    self.rawInboundMessages = inboundChannels.rawInboundMessages.stream
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
    if let pending = await state.close() {
      for pendingResponse in pending {
        pendingResponse.fail(CodexAppServerClientError.closed)
      }
      inboundChannels.finish()
    }
    readTask.cancel()
    await transport.close()
    await readTask.value
  }
}

struct CodexAppServerInboundChannels: Sendable {
  let unhandled = AsyncThrowingStream<CodexAppServerUnhandledInboundMessage, Error>.makeStream(
    bufferingPolicy: .bufferingNewest(64))
  let mode: CodexAppServerClient.InboundMessageMode
  let connectionID = UUID()
  let notifications =
    CodexAppServerAsyncThrowingChannel<CodexAppServerProtocol.Stable.ServerNotification>()
  let typedServerRequests =
    CodexAppServerAsyncThrowingChannel<CodexAppServerTypedServerRequest>()
  let rawNotifications = CodexAppServerAsyncThrowingChannel<CodexAppServerRawNotification>()
  let rawServerRequests = CodexAppServerAsyncThrowingChannel<CodexAppServerRawServerRequest>()
  let rawInboundMessages = CodexAppServerAsyncThrowingChannel<CodexAppServerRawInboundMessage>()

  init(mode: CodexAppServerClient.InboundMessageMode) {
    self.mode = mode
    // Inactive streams terminate immediately; they never buffer unconsumed copies.
    switch mode {
    case .typed:
      rawNotifications.finish()
      rawServerRequests.finish()
      rawInboundMessages.finish()
    case .raw:
      unhandled.continuation.finish()
      notifications.finish()
      typedServerRequests.finish()
      rawInboundMessages.finish()
    case .rawOrdered:
      unhandled.continuation.finish()
      notifications.finish()
      typedServerRequests.finish()
      rawNotifications.finish()
      rawServerRequests.finish()
    }
  }

  func finish(throwing error: (any Error)? = nil) {
    if let error {
      unhandled.continuation.finish(throwing: error)
      notifications.finish(throwing: error)
      typedServerRequests.finish(throwing: error)
      rawNotifications.finish(throwing: error)
      rawServerRequests.finish(throwing: error)
      rawInboundMessages.finish(throwing: error)
    } else {
      unhandled.continuation.finish()
      notifications.finish()
      typedServerRequests.finish()
      rawNotifications.finish()
      rawServerRequests.finish()
      rawInboundMessages.finish()
    }
  }
}
