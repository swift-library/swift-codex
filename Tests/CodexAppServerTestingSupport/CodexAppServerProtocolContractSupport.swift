import CodexAppServerProtocol
import CodexAppServerRuntime
import Foundation

public enum CodexAppServerProtocolContractSupport {
  public typealias Stable = CodexAppServerProtocol.Stable

  public enum Initialize {
    public static let invalidRequestErrorCode: Int64 = -32600

    public enum ContractError: Error, Equatable, Sendable {
      case expectedInitializeRequest
      case expectedInitializedNotification
      case unexpectedClientMessage
      case requestIDRequired
    }

    public enum ClientMessageResult: Equatable, Sendable {
      case initializeResponse(request: Stable.ClientRequest.InitializeRequest, line: String)
      case initializedNotification(Stable.ClientNotification.InitializedNotification)
      case requestBeforeInitializeError(line: String)
      case alreadyInitializedError(line: String)
      case initializedRequest(id: Stable.RequestId, method: String, params: Stable.JSONValue?)
      case ignoredNotification(method: String)
    }

    public struct Session: Sendable {
      public let initializeResponse: Stable.InitializeResponse
      public private(set) var didInitialize = false
      public private(set) var didReceiveInitializedNotification = false

      public init(initializeResponse: Stable.InitializeResponse) {
        self.initializeResponse = initializeResponse
      }

      public mutating func handleClientLine(_ line: String) throws -> ClientMessageResult {
        let envelope = try CodexAppServerConnectionFoundation.decodeLine(line)

        switch try envelope.classify() {
        case .request(let id, let method, _):
          let stableID = Stable.RequestId(id)

          if method == "initialize" {
            if didInitialize {
              return .alreadyInitializedError(
                line: try Self.encodeErrorLine(
                  id: stableID,
                  message: "Already initialized"
                )
              )
            }

            let request = try Self.decodeInitializeRequest(from: line)
            didInitialize = true
            return .initializeResponse(
              request: request,
              line: try Self.encodeInitializeResponseLine(
                id: request.id,
                response: initializeResponse
              )
            )
          }

          guard didInitialize else {
            return .requestBeforeInitializeError(
              line: try Self.encodeErrorLine(id: stableID, message: "Not initialized")
            )
          }

          return .initializedRequest(
            id: stableID,
            method: method,
            params: envelope.params.map(Stable.JSONValue.init(rawValue:))
          )

        case .notification(let method, _):
          if method == "initialized" {
            let notification = try Self.decodeInitializedNotification(from: line)
            didReceiveInitializedNotification = true
            return .initializedNotification(notification)
          }

          return .ignoredNotification(method: method)

        case .success, .failure:
          throw ContractError.unexpectedClientMessage
        }
      }

      private static func decodeInitializeRequest(
        from line: String
      ) throws -> Stable.ClientRequest.InitializeRequest {
        try Initialize.decodeInitializeRequest(from: line)
      }

      private static func encodeInitializeResponseLine(
        id: Stable.RequestId,
        response: Stable.InitializeResponse
      ) throws -> String {
        try Initialize.encodeInitializeResponseLine(id: id, response: response)
      }

      private static func encodeErrorLine(id: Stable.RequestId, message: String) throws -> String {
        try Initialize.encodeErrorLine(id: id, message: message)
      }

      private static func decodeInitializedNotification(
        from line: String
      ) throws -> Stable.ClientNotification.InitializedNotification {
        try Initialize.decodeInitializedNotification(from: line)
      }
    }

    public static func decodeInitializeRequest(
      from line: String
    ) throws -> Stable.ClientRequest.InitializeRequest {
      let request = try decode(Stable.ClientRequest.self, from: line)

      guard case .initializerequest(let value) = request else {
        throw ContractError.expectedInitializeRequest
      }

      return value
    }

    public static func encodeInitializeResponseLine(
      id: Stable.RequestId,
      response: Stable.InitializeResponse
    ) throws -> String {
      let rpcResponse = Stable.JSONRPCResponse(
        id: id,
        result: try Stable.JSONValue(response)
      )

      return try CodexAppServerConnectionFoundation.encodeLine(rpcResponse)
    }

    public static func decodeInitializedNotification(
      from line: String
    ) throws -> Stable.ClientNotification.InitializedNotification {
      let notification = try decode(Stable.ClientNotification.self, from: line)

      guard case .initializednotification(let value) = notification else {
        throw ContractError.expectedInitializedNotification
      }

      return value
    }

    public static func encodeErrorLine(id: Stable.RequestId, message: String) throws -> String {
      let rpcError = Stable.JSONRPCError(
        error: Stable.JSONRPCErrorError(
          code: invalidRequestErrorCode,
          data: nil,
          message: message
        ),
        id: id
      )

      return try CodexAppServerConnectionFoundation.encodeLine(rpcError)
    }
  }

  public enum ThreadStart {
    public static let threadStartedMethod = "thread/started"

    public enum ContractError: Error, Equatable, Sendable {
      case expectedThreadStartRequest
    }

    public struct Exchange: Equatable, Sendable {
      public let request: Stable.ClientRequest.ThreadStartRequest
      public let responseLine: String
      public let notificationLine: String?

      public init(
        request: Stable.ClientRequest.ThreadStartRequest,
        responseLine: String,
        notificationLine: String?
      ) {
        self.request = request
        self.responseLine = responseLine
        self.notificationLine = notificationLine
      }
    }

    public static func decodeThreadStartRequest(
      from line: String
    ) throws -> Stable.ClientRequest.ThreadStartRequest {
      let request = try decode(Stable.ClientRequest.self, from: line)

      guard case .threadStartRequest(let value) = request else {
        throw ContractError.expectedThreadStartRequest
      }

      return value
    }

    public static func makeThreadStartExchange(
      requestLine: String,
      response: Stable.ThreadStartResponse,
      notificationOptOutMethods: Set<String> = []
    ) throws -> Exchange {
      let request = try decodeThreadStartRequest(from: requestLine)
      let notificationLine =
        notificationOptOutMethods.contains(threadStartedMethod)
        ? nil
        : try encodeThreadStartedNotificationLine(.init(thread: response.thread))

      return Exchange(
        request: request,
        responseLine: try encodeThreadStartResponseLine(id: request.id, response: response),
        notificationLine: notificationLine
      )
    }

    public static func encodeThreadStartResponseLine(
      id: Stable.RequestId,
      response: Stable.ThreadStartResponse
    ) throws -> String {
      let rpcResponse = Stable.JSONRPCResponse(
        id: id,
        result: try Stable.JSONValue(response)
      )

      return try CodexAppServerConnectionFoundation.encodeLine(rpcResponse)
    }

    public static func encodeThreadStartedNotificationLine(
      _ notification: Stable.ThreadStartedNotification
    ) throws -> String {
      let serverNotification = Stable.ServerNotification.threadStartedNotification(
        .init(method: .threadStarted, params: notification)
      )

      return try CodexAppServerConnectionFoundation.encodeLine(serverNotification)
    }
  }

  public enum TurnStart {
    public static let turnStartedMethod = "turn/started"

    public enum ContractError: Error, Equatable, Sendable {
      case expectedTurnStartRequest
    }

    public struct Exchange: Equatable, Sendable {
      public let request: Stable.ClientRequest.TurnStartRequest
      public let responseLine: String
      public let notificationLine: String?

      public init(
        request: Stable.ClientRequest.TurnStartRequest,
        responseLine: String,
        notificationLine: String?
      ) {
        self.request = request
        self.responseLine = responseLine
        self.notificationLine = notificationLine
      }
    }

    public static func decodeTurnStartRequest(
      from line: String
    ) throws -> Stable.ClientRequest.TurnStartRequest {
      let request = try decode(Stable.ClientRequest.self, from: line)

      guard case .turnStartRequest(let value) = request else {
        throw ContractError.expectedTurnStartRequest
      }

      return value
    }

    public static func makeTurnStartExchange(
      requestLine: String,
      response: Stable.TurnStartResponse,
      notificationOptOutMethods: Set<String> = []
    ) throws -> Exchange {
      let request = try decodeTurnStartRequest(from: requestLine)
      let notificationLine =
        notificationOptOutMethods.contains(turnStartedMethod)
        ? nil
        : try encodeTurnStartedNotificationLine(
          .init(threadId: request.params.threadId, turn: response.turn)
        )

      return Exchange(
        request: request,
        responseLine: try encodeTurnStartResponseLine(id: request.id, response: response),
        notificationLine: notificationLine
      )
    }

    public static func encodeTurnStartResponseLine(
      id: Stable.RequestId,
      response: Stable.TurnStartResponse
    ) throws -> String {
      let rpcResponse = Stable.JSONRPCResponse(
        id: id,
        result: try Stable.JSONValue(response)
      )

      return try CodexAppServerConnectionFoundation.encodeLine(rpcResponse)
    }

    public static func encodeTurnStartedNotificationLine(
      _ notification: Stable.TurnStartedNotification
    ) throws -> String {
      let serverNotification = Stable.ServerNotification.turnStartedNotification(
        .init(method: .turnStarted, params: notification)
      )

      return try CodexAppServerConnectionFoundation.encodeLine(serverNotification)
    }
  }

  private static func decode<T: Decodable>(_ type: T.Type, from line: String) throws -> T {
    guard let data = line.data(using: .utf8) else {
      throw CodexAppServerConnectionFoundation.FoundationError.invalidUTF8
    }

    return try JSONDecoder().decode(type, from: data)
  }
}

extension CodexAppServerProtocol.Stable.RequestId {
  public init(_ requestID: CodexAppServerConnectionFoundation.RequestID) {
    switch requestID {
    case .string(let value):
      self = .requestidoption1(value)
    case .integer(let value):
      self = .requestidoption2(value)
    }
  }
}

extension CodexAppServerProtocol.Stable.JSONValue {
  public init(_ value: some Encodable) throws {
    let data = try JSONEncoder().encode(value)
    self = try JSONDecoder().decode(Self.self, from: data)
  }

  public init(rawValue: CodexAppServerConnectionFoundation.JSONValue) {
    switch rawValue {
    case .null:
      self = .null
    case .bool(let value):
      self = .bool(value)
    case .number(let value):
      self = .number(Self.stableJSONNumber(value))
    case .string(let value):
      self = .string(value)
    case .array(let value):
      self = .array(value.map(Self.init(rawValue:)))
    case .object(let value):
      self = .object(value.mapValues(Self.init(rawValue:)))
    }
  }

  private static func stableJSONNumber(
    _ value: CodexAppServerConnectionFoundation.JSONNumber
  ) -> CodexAppServerProtocol.Stable.JSONNumber {
    switch value {
    case .integer(let value):
      return .integer(value)
    case .decimal(let value):
      return .decimal(value)
    }
  }
}
