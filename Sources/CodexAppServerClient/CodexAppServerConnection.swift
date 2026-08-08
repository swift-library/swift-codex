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

  let transport: any CodexAppServerMessageTransport
  let state: CodexAppServerConnectionState
  private let notificationChannel:
    CodexAppServerAsyncThrowingChannel<CodexAppServerProtocol.Stable.ServerNotification>
  private let typedServerRequestChannel:
    CodexAppServerAsyncThrowingChannel<CodexAppServerTypedServerRequest>
  private let readTask: Task<Void, Never>

  init(transport: any CodexAppServerMessageTransport) {
    let notificationChannel =
      CodexAppServerAsyncThrowingChannel<CodexAppServerProtocol.Stable.ServerNotification>()
    let typedServerRequestChannel =
      CodexAppServerAsyncThrowingChannel<CodexAppServerTypedServerRequest>()
    let state = CodexAppServerConnectionState()

    self.transport = transport
    self.state = state
    self.notificationChannel = notificationChannel
    self.typedServerRequestChannel = typedServerRequestChannel
    self.notifications = notificationChannel.stream
    self.typedServerRequests = typedServerRequestChannel.stream
    self.readTask = Task {
      await Self.consumeInboundMessages(
        from: transport,
        state: state,
        notificationChannel: notificationChannel,
        typedServerRequestChannel: typedServerRequestChannel
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
    notificationChannel.finish()
    typedServerRequestChannel.finish()
  }
}
