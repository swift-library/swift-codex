import CodexAppServerRuntime
import Foundation

public struct CodexAppServerClient: Sendable {
  /// Selects the representation used by the connection's inbound streams.
  public enum InboundMessageMode: Equatable, Sendable {
    /// Decode the pinned stable protocol into typed notifications and requests.
    case typed
    /// Preserve complete JSON payloads, including experimental and unknown fields.
    case raw
  }

  public struct ClientInfo: Equatable, Sendable {
    public var name: String
    public var title: String?
    public var version: String

    public init(
      name: String,
      title: String? = nil,
      version: String
    ) {
      self.name = name
      self.title = title
      self.version = version
    }
  }

  public struct SessionConfiguration: Equatable, Sendable {
    public var clientInfo: ClientInfo
    public var experimentalApi: Bool
    public var optOutNotificationMethods: [String]
    public var inboundMessageMode: InboundMessageMode

    public init(
      clientInfo: ClientInfo,
      experimentalApi: Bool = false,
      optOutNotificationMethods: [String] = [],
      inboundMessageMode: InboundMessageMode = .typed
    ) {
      self.clientInfo = clientInfo
      self.experimentalApi = experimentalApi
      self.optOutNotificationMethods = optOutNotificationMethods
      self.inboundMessageMode = inboundMessageMode
    }
  }

  public let sessionConfiguration: SessionConfiguration

  private let transportFactory: @Sendable () async throws -> any CodexAppServerMessageTransport

  public init(
    sessionConfiguration: SessionConfiguration,
    transportFactory: @escaping @Sendable () async throws -> any CodexAppServerMessageTransport
  ) {
    self.sessionConfiguration = sessionConfiguration
    self.transportFactory = transportFactory
  }

  public func start() async throws -> CodexAppServerConnection {
    let transport = try await transportFactory()
    let connection = CodexAppServerConnection(
      transport: transport, inboundMessageMode: sessionConfiguration.inboundMessageMode)

    do {
      _ = try await connection.performInitialize(configuration: sessionConfiguration)
      try await connection.sendStableInitializedNotification()
      return connection
    } catch {
      await connection.close()
      throw error
    }
  }
}
