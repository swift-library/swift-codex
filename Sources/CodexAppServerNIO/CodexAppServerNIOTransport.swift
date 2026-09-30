import CodexAppServerRuntime
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket

public enum CodexAppServerNIOError: Error, Equatable, Sendable {
  case closed
  case invalidURL
  case invalidUnixSocketPath
  case invalidRequestURI
  case invalidHostHeader
  case missingHost
  case unsupportedScheme(String?)
  case invalidUTF8
  case unsupportedFrame
  case upgradeRejected
}

extension CodexAppServerNIOError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .closed:
      "The Codex WebSocket transport is closed."
    case .invalidURL:
      "The Codex WebSocket URL is invalid."
    case .invalidUnixSocketPath:
      "The Codex Unix socket path must be absolute and fit the platform address limit."
    case .invalidRequestURI:
      "The Codex WebSocket request path is invalid."
    case .invalidHostHeader:
      "The Codex WebSocket Host header is invalid."
    case .missingHost:
      "The Codex WebSocket URL has no host."
    case .unsupportedScheme(let scheme):
      "The Codex WebSocket URL scheme is unsupported: \(scheme ?? "missing")."
    case .invalidUTF8:
      "The Codex WebSocket returned a message that is not valid UTF-8."
    case .unsupportedFrame:
      "The Codex WebSocket returned an unsupported frame."
    case .upgradeRejected:
      "The Codex app-server rejected the WebSocket upgrade."
    }
  }
}

public struct CodexAppServerNIOHeader: Equatable, Sendable {
  public var name: String
  public var value: String

  public init(name: String, value: String) {
    self.name = name
    self.value = value
  }
}

public struct CodexAppServerNIOConfiguration: Equatable, Sendable {
  public var maxFrameSize: Int
  public var additionalHeaders: [CodexAppServerNIOHeader]

  public init(
    maxFrameSize: Int = 1 << 20,
    additionalHeaders: [CodexAppServerNIOHeader] = []
  ) {
    self.maxFrameSize = maxFrameSize
    self.additionalHeaders = additionalHeaders
  }
}

public final class CodexAppServerNIOTransport: CodexAppServerMessageTransport,
  @unchecked Sendable
{
  public let inboundMessages: AsyncThrowingStream<String, Error>

  private let webSocket: any CodexAppServerNIOWebSocket
  private let inboundChannel: CodexAppServerAsyncThrowingChannel<String>
  private let state: CodexAppServerNIOTransportState
  private let receiveTask: Task<Void, Never>

  public static func connect(
    url: URL,
    eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
    configuration: CodexAppServerNIOConfiguration = .init()
  ) async throws -> CodexAppServerNIOTransport {
    let endpoint = try CodexAppServerNIOEndpoint(url: url)
    return try await connect(
      endpoint: endpoint,
      eventLoopGroup: eventLoopGroup,
      configuration: configuration,
      connector: CodexAppServerNIONIOConnector()
    )
  }

  /// Connects to a WebSocket App Server endpoint over a Unix domain socket.
  ///
  /// Codex's `unix://` listener still speaks an HTTP WebSocket upgrade and
  /// framed WebSocket messages. It is not a newline-delimited stdio socket.
  public static func connect(
    unixSocketPath: String,
    requestURI: String = "/",
    hostHeader: String = "localhost",
    eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
    configuration: CodexAppServerNIOConfiguration = .init()
  ) async throws -> CodexAppServerNIOTransport {
    let endpoint = try CodexAppServerNIOEndpoint(
      unixSocketPath: unixSocketPath,
      requestURI: requestURI,
      hostHeader: hostHeader
    )
    return try await connect(
      endpoint: endpoint,
      eventLoopGroup: eventLoopGroup,
      configuration: configuration,
      connector: CodexAppServerNIONIOConnector()
    )
  }

  static func connect(
    url: URL,
    eventLoopGroup: any EventLoopGroup,
    configuration: CodexAppServerNIOConfiguration,
    connector: any CodexAppServerNIOWebSocketConnector
  ) async throws -> CodexAppServerNIOTransport {
    try await connect(
      endpoint: CodexAppServerNIOEndpoint(url: url),
      eventLoopGroup: eventLoopGroup,
      configuration: configuration,
      connector: connector
    )
  }

  static func connect(
    unixSocketPath: String,
    requestURI: String = "/",
    hostHeader: String = "localhost",
    eventLoopGroup: any EventLoopGroup,
    configuration: CodexAppServerNIOConfiguration,
    connector: any CodexAppServerNIOWebSocketConnector
  ) async throws -> CodexAppServerNIOTransport {
    try await connect(
      endpoint: CodexAppServerNIOEndpoint(
        unixSocketPath: unixSocketPath,
        requestURI: requestURI,
        hostHeader: hostHeader
      ),
      eventLoopGroup: eventLoopGroup,
      configuration: configuration,
      connector: connector
    )
  }

  private static func connect(
    endpoint: CodexAppServerNIOEndpoint,
    eventLoopGroup: any EventLoopGroup,
    configuration: CodexAppServerNIOConfiguration,
    connector: any CodexAppServerNIOWebSocketConnector
  ) async throws -> CodexAppServerNIOTransport {
    let webSocket = try await connector.connect(
      endpoint: endpoint,
      eventLoopGroup: eventLoopGroup,
      configuration: configuration
    )
    return CodexAppServerNIOTransport(webSocket: webSocket)
  }

  init(webSocket: any CodexAppServerNIOWebSocket) {
    let inboundChannel = CodexAppServerAsyncThrowingChannel<String>()
    let state = CodexAppServerNIOTransportState()

    self.webSocket = webSocket
    self.inboundChannel = inboundChannel
    self.state = state
    self.inboundMessages = inboundChannel.stream
    self.receiveTask = Task { [webSocket, inboundChannel, state] in
      do {
        try await Self.receiveMessages(
          from: webSocket,
          into: inboundChannel,
          state: state
        )
      } catch is CancellationError {
        inboundChannel.finish()
      } catch {
        inboundChannel.finish(throwing: error)
        await state.markClosed()
        await webSocket.close()
      }
    }
  }

  public func sendMessage(_ message: String) async throws {
    try await state.checkOpen()
    try await webSocket.sendFrame(Self.textFrame(message))
  }

  public func close() async {
    guard await state.close() else {
      return
    }

    receiveTask.cancel()
    await webSocket.close()
    inboundChannel.finish()
  }

  private static func receiveMessages(
    from webSocket: any CodexAppServerNIOWebSocket,
    into inboundChannel: CodexAppServerAsyncThrowingChannel<String>,
    state: CodexAppServerNIOTransportState
  ) async throws {
    for try await frame in webSocket.inboundFrames {
      switch frame.opcode {
      case .text, .binary:
        try inboundChannel.yield(try string(from: frame), byteCount: frame.data.readableBytes)
      case .ping:
        try await webSocket.sendFrame(
          WebSocketFrame(
            fin: true,
            opcode: .pong,
            maskKey: maskingKey(),
            data: frame.data
          )
        )
      case .pong:
        continue
      case .connectionClose:
        await state.markClosed()
        inboundChannel.finish()
        return
      case .continuation:
        throw CodexAppServerNIOError.unsupportedFrame
      default:
        throw CodexAppServerNIOError.unsupportedFrame
      }
    }

    await state.markClosed()
    inboundChannel.finish()
  }

  private static func textFrame(_ message: String) -> WebSocketFrame {
    WebSocketFrame(
      fin: true,
      opcode: .text,
      maskKey: maskingKey(),
      data: ByteBuffer(string: message)
    )
  }

  private static func maskingKey() -> WebSocketMaskingKey {
    var generator = SystemRandomNumberGenerator()
    return [
      UInt8.random(in: .min ... .max, using: &generator),
      UInt8.random(in: .min ... .max, using: &generator),
      UInt8.random(in: .min ... .max, using: &generator),
      UInt8.random(in: .min ... .max, using: &generator),
    ]
  }

  private static func string(from frame: WebSocketFrame) throws -> String {
    var data = frame.data
    let bytes = data.readBytes(length: data.readableBytes) ?? []
    guard let message = String(data: Data(bytes), encoding: .utf8) else {
      throw CodexAppServerNIOError.invalidUTF8
    }
    return message
  }
}

protocol CodexAppServerNIOWebSocket: Sendable {
  var inboundFrames: AsyncThrowingStream<WebSocketFrame, Error> { get }

  func sendFrame(_ frame: WebSocketFrame) async throws
  func close() async
}

protocol CodexAppServerNIOWebSocketConnector: Sendable {
  func connect(
    endpoint: CodexAppServerNIOEndpoint,
    eventLoopGroup: any EventLoopGroup,
    configuration: CodexAppServerNIOConfiguration
  ) async throws -> any CodexAppServerNIOWebSocket
}

private actor CodexAppServerNIOTransportState {
  private var isClosed = false

  func checkOpen() throws {
    if isClosed {
      throw CodexAppServerNIOError.closed
    }
  }

  func close() -> Bool {
    if isClosed {
      return false
    }

    isClosed = true
    return true
  }

  func markClosed() {
    isClosed = true
  }
}

struct CodexAppServerNIOEndpoint: Equatable, Sendable {
  enum Target: Equatable, Sendable {
    case hostPort(host: String, port: Int)
    case unixSocket(path: String)
  }

  var target: Target
  var host: String
  var hostHeader: String
  var uri: String
  var usesTLS: Bool

  init(url: URL) throws {
    guard let scheme = url.scheme else {
      throw CodexAppServerNIOError.invalidURL
    }

    switch scheme.lowercased() {
    case "ws":
      usesTLS = false
    case "wss":
      usesTLS = true
    default:
      throw CodexAppServerNIOError.unsupportedScheme(url.scheme)
    }

    guard let host = url.host(percentEncoded: false), !host.isEmpty else {
      throw CodexAppServerNIOError.missingHost
    }

    self.host = host
    let port = url.port ?? (usesTLS ? 443 : 80)
    self.target = .hostPort(host: host, port: port)
    self.hostHeader = url.port == nil ? host : "\(host):\(port)"

    var uri = url.path(percentEncoded: true)
    if uri.isEmpty {
      uri = "/"
    }
    if let query = url.query(percentEncoded: true), !query.isEmpty {
      uri += "?\(query)"
    }
    self.uri = uri
  }

  init(
    unixSocketPath: String,
    requestURI: String,
    hostHeader: String
  ) throws {
    guard
      !unixSocketPath.isEmpty,
      (unixSocketPath as NSString).isAbsolutePath,
      !unixSocketPath.utf8.contains(0)
    else {
      throw CodexAppServerNIOError.invalidUnixSocketPath
    }
    do {
      _ = try SocketAddress(unixDomainSocketPath: unixSocketPath)
    } catch {
      throw CodexAppServerNIOError.invalidUnixSocketPath
    }
    guard
      requestURI.hasPrefix("/"),
      !requestURI.utf8.contains(0),
      !Self.containsLineBreak(requestURI)
    else {
      throw CodexAppServerNIOError.invalidRequestURI
    }
    guard
      !hostHeader.isEmpty,
      !hostHeader.utf8.contains(0),
      !Self.containsLineBreak(hostHeader)
    else {
      throw CodexAppServerNIOError.invalidHostHeader
    }

    self.target = .unixSocket(path: unixSocketPath)
    self.host = "localhost"
    self.hostHeader = hostHeader
    self.uri = requestURI
    self.usesTLS = false
  }

  private static func containsLineBreak(_ value: String) -> Bool {
    value.unicodeScalars.contains { CharacterSet.newlines.contains($0) }
  }
}

private struct CodexAppServerNIONIOConnector:
  CodexAppServerNIOWebSocketConnector
{
  func connect(
    endpoint: CodexAppServerNIOEndpoint,
    eventLoopGroup: any EventLoopGroup,
    configuration: CodexAppServerNIOConfiguration
  ) async throws -> any CodexAppServerNIOWebSocket {
    let bootstrap = ClientBootstrap(group: eventLoopGroup)
    let channelInitializer:
      @Sendable (any Channel) -> EventLoopFuture<
        EventLoopFuture<CodexAppServerNIONIOUpgradeResult>
      > = { channel in
        channel.eventLoop.makeCompletedFuture {
          if endpoint.usesTLS {
            let tlsContext = try NIOSSLContext(
              configuration: TLSConfiguration.makeClientConfiguration())
            let tlsHandler = try NIOSSLClientHandler(
              context: tlsContext,
              serverHostname: endpoint.host
            )
            try channel.pipeline.syncOperations.addHandler(tlsHandler)
          }

          let upgrader = NIOTypedWebSocketClientUpgrader<
            CodexAppServerNIONIOUpgradeResult
          >(
            maxFrameSize: configuration.maxFrameSize,
            upgradePipelineHandler: { channel, _ in
              channel.eventLoop.makeCompletedFuture {
                let asyncChannel = try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(
                  wrappingChannelSynchronously: channel
                )
                return .webSocket(asyncChannel)
              }
            }
          )

          var headers = HTTPHeaders()
          headers.add(name: "Host", value: endpoint.hostHeader)
          headers.add(name: "Content-Length", value: "0")
          for header in configuration.additionalHeaders {
            headers.add(name: header.name, value: header.value)
          }

          let requestHead = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: endpoint.uri,
            headers: headers
          )
          let upgradeConfiguration = NIOTypedHTTPClientUpgradeConfiguration(
            upgradeRequestHead: requestHead,
            upgraders: [upgrader],
            notUpgradingCompletionHandler: { channel in
              channel.eventLoop.makeSucceededFuture(
                CodexAppServerNIONIOUpgradeResult.notUpgraded
              )
            }
          )

          return try channel.pipeline.syncOperations.configureUpgradableHTTPClientPipeline(
            configuration: .init(upgradeConfiguration: upgradeConfiguration)
          )
        }
      }

    let upgradeResult: EventLoopFuture<CodexAppServerNIONIOUpgradeResult> =
      switch endpoint.target {
      case .hostPort(let host, let port):
        try await bootstrap.connect(
          host: host,
          port: port,
          channelInitializer: channelInitializer
        )
      case .unixSocket(let path):
        try await bootstrap.connect(
          unixDomainSocketPath: path,
          channelInitializer: channelInitializer
        )
      }

    switch try await upgradeResult.get() {
    case .webSocket(let channel):
      return CodexAppServerNIONIOWebSocket(asyncChannel: channel)
    case .notUpgraded:
      throw CodexAppServerNIOError.upgradeRejected
    }
  }
}

private enum CodexAppServerNIONIOUpgradeResult: Sendable {
  case webSocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>)
  case notUpgraded
}

private final class CodexAppServerNIONIOWebSocket:
  CodexAppServerNIOWebSocket, @unchecked Sendable
{
  let inboundFrames: AsyncThrowingStream<WebSocketFrame, Error>

  private let asyncChannel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>
  private let inboundChannel: CodexAppServerAsyncThrowingChannel<WebSocketFrame>
  private let outbound: CodexAppServerNIONIOOutbound
  private let runTask: Task<Void, Never>

  init(asyncChannel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>) {
    let inboundChannel = CodexAppServerAsyncThrowingChannel<WebSocketFrame>()
    let outbound = CodexAppServerNIONIOOutbound()

    self.asyncChannel = asyncChannel
    self.inboundChannel = inboundChannel
    self.outbound = outbound
    self.inboundFrames = inboundChannel.stream
    self.runTask = Task { [asyncChannel, inboundChannel, outbound] in
      do {
        try await asyncChannel.executeThenClose { inbound, writer in
          await outbound.activate(writer)
          for try await frame in inbound {
            try inboundChannel.yield(frame, byteCount: frame.data.readableBytes)
          }
        }
        inboundChannel.finish()
      } catch {
        inboundChannel.finish(throwing: error)
      }
      await outbound.close()
    }
  }

  func sendFrame(_ frame: WebSocketFrame) async throws {
    try await outbound.write(frame)
  }

  func close() async {
    await outbound.finish()
    try? await asyncChannel.channel.close().get()
    runTask.cancel()
    inboundChannel.finish()
  }
}

private actor CodexAppServerNIONIOOutbound {
  typealias Writer = NIOAsyncChannelOutboundWriter<WebSocketFrame>

  private var writer: Writer?
  private var waiters: [CheckedContinuation<Writer, Error>] = []
  private var isClosed = false

  func activate(_ writer: Writer) {
    guard !isClosed else {
      writer.finish()
      return
    }

    self.writer = writer
    let waiters = self.waiters
    self.waiters.removeAll(keepingCapacity: false)
    for waiter in waiters {
      waiter.resume(returning: writer)
    }
  }

  func write(_ frame: WebSocketFrame) async throws {
    let writer = try await activeWriter()
    try await writer.write(frame)
  }

  func finish() {
    isClosed = true
    writer?.finish()
    writer = nil
    let waiters = self.waiters
    self.waiters.removeAll(keepingCapacity: false)
    for waiter in waiters {
      waiter.resume(throwing: CodexAppServerNIOError.closed)
    }
  }

  func close() {
    finish()
  }

  private func activeWriter() async throws -> Writer {
    if let writer {
      return writer
    }
    if isClosed {
      throw CodexAppServerNIOError.closed
    }

    return try await withCheckedThrowingContinuation { continuation in
      waiters.append(continuation)
    }
  }
}
