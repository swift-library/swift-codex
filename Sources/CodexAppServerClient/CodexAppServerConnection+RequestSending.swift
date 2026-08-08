import CodexAppServerProtocol
import CodexAppServerRuntime
import Foundation

extension CodexAppServerConnection {
  func sendStableRequest<Response: Decodable & Sendable>(
    method: String,
    responseType: Response.Type,
    id explicitID: CodexAppServerProtocol.Stable.RequestId? = nil
  ) async throws -> Response {
    try await _sendStableRequest(
      method: method,
      params: nil,
      responseType: responseType,
      id: explicitID
    )
  }

  func sendStableRequest<Params: Encodable & Sendable, Response: Decodable & Sendable>(
    method: String,
    params: Params,
    responseType: Response.Type,
    id explicitID: CodexAppServerProtocol.Stable.RequestId? = nil
  ) async throws -> Response {
    try await _sendStableRequest(
      method: method,
      params: Self.encodeStableJSONValue(params),
      responseType: responseType,
      id: explicitID
    )
  }

  func _sendStableRequest<Response: Decodable & Sendable>(
    method: String,
    params: CodexAppServerProtocol.Stable.JSONValue?,
    responseType: Response.Type,
    id explicitID: CodexAppServerProtocol.Stable.RequestId?
  ) async throws -> Response {
    let rawID = try await Self.mapRuntimeStateError {
      try await state.allocateRequestID(explicitID.map(Self.runtimeRequestID))
    }
    let id = Self.stableRequestID(rawID)
    let pendingResponse = CodexAppServerPendingResponse()
    let request = CodexAppServerProtocol.Stable.JSONRPCRequest(
      id: id,
      method: method,
      params: params,
      trace: nil
    )
    let line = try Self.encodeStableLine(request)

    try await Self.mapRuntimeStateError {
      try await state.addPending(id: rawID, pendingResponse: pendingResponse)
    }

    do {
      try await transport.sendMessage(line)
      let result = try await withTaskCancellationHandler {
        try await pendingResponse.wait()
      } onCancel: {
        Task {
          await self.state.cancelPending(
            id: rawID,
            error: CodexAppServerClientError.requestCancelled
          )
        }
      }

      return try Self.decodeStableJSONValue(result, as: responseType)
    } catch {
      await state.removePending(id: rawID)
      throw error
    }
  }

  func sendStableMessage(_ value: some Encodable) async throws {
    let line = try Self.encodeStableLine(value)
    try await transport.sendMessage(line)
  }

  static func consumeInboundMessages(
    from transport: any CodexAppServerMessageTransport,
    state: CodexAppServerConnectionState,
    notificationChannel: CodexAppServerAsyncThrowingChannel<
      CodexAppServerProtocol.Stable.ServerNotification
    >,
    typedServerRequestChannel: CodexAppServerAsyncThrowingChannel<CodexAppServerTypedServerRequest>
  ) async {
    do {
      for try await line in transport.inboundMessages {
        try await handleInboundMessage(
          line,
          state: state,
          notificationChannel: notificationChannel,
          typedServerRequestChannel: typedServerRequestChannel
        )
      }
      await failConnection(
        CodexAppServerClientError.peerClosed,
        state: state,
        notificationChannel: notificationChannel,
        typedServerRequestChannel: typedServerRequestChannel
      )
    } catch is CancellationError {
      await failConnection(
        CodexAppServerClientError.closed,
        state: state,
        notificationChannel: notificationChannel,
        typedServerRequestChannel: typedServerRequestChannel
      )
    } catch {
      await failConnection(
        error,
        state: state,
        notificationChannel: notificationChannel,
        typedServerRequestChannel: typedServerRequestChannel
      )
    }
  }

  private static func handleInboundMessage(
    _ line: String,
    state: CodexAppServerConnectionState,
    notificationChannel: CodexAppServerAsyncThrowingChannel<
      CodexAppServerProtocol.Stable.ServerNotification
    >,
    typedServerRequestChannel: CodexAppServerAsyncThrowingChannel<CodexAppServerTypedServerRequest>
  ) async throws {
    let envelope: CodexAppServerConnectionFoundation.RawEnvelope
    do {
      envelope = try CodexAppServerConnectionFoundation.decodeLine(line)
    } catch {
      throw CodexAppServerClientError.malformedInbound(
        "envelope decode failed: \(error.localizedDescription)"
      )
    }

    let message: CodexAppServerConnectionFoundation.RawMessage
    do {
      message = try envelope.classify()
    } catch {
      throw CodexAppServerClientError.malformedInbound(
        "envelope classification failed (keys: \(Self.envelopeKeys(envelope))): "
          + error.localizedDescription
      )
    }

    switch message {
    case .success(let rawID, let result):
      let id = stableRequestID(rawID)
      guard let pendingResponse = await state.takePending(id: rawID) else {
        if await state.consumeCancelledResponse(id: rawID) {
          return
        }
        throw CodexAppServerClientError.unmatchedResponse(id: id)
      }
      pendingResponse.succeed(result ?? .null)

    case .failure(let rawID, let error):
      guard let rawID else {
        throw CodexAppServerClientError.malformedInbound(
          "JSON-RPC error response is missing an id."
        )
      }

      let id = stableRequestID(rawID)
      guard let pendingResponse = await state.takePending(id: rawID) else {
        if await state.consumeCancelledResponse(id: rawID) {
          return
        }
        throw CodexAppServerClientError.unmatchedResponse(id: id)
      }
      pendingResponse.fail(
        CodexAppServerClientError.jsonRPCError(
          code: error.code,
          message: error.message,
          data: error.data.map(stableJSONValue)
        )
      )

    case .notification:
      let notification: CodexAppServerProtocol.Stable.ServerNotification
      do {
        notification = try decodeStableLine(
          CodexAppServerProtocol.Stable.ServerNotification.self,
          from: line
        )
      } catch {
        throw CodexAppServerClientError.malformedInbound(
          "notification '\(envelope.method ?? "<missing>")' decode failed: "
            + error.localizedDescription
        )
      }
      notificationChannel.yield(notification)

    case .request:
      let request: CodexAppServerProtocol.Stable.ServerRequest
      do {
        request = try decodeStableLine(
          CodexAppServerProtocol.Stable.ServerRequest.self,
          from: line
        )
      } catch {
        throw CodexAppServerClientError.malformedInbound(error.localizedDescription)
      }

      let serverRequest = CodexAppServerServerRequest(request: request)
      try await mapRuntimeStateError {
        try await state.addServerRequest(id: runtimeRequestID(serverRequest.id))
      }
      typedServerRequestChannel.yield(
        CodexAppServerTypedServerRequest(serverRequest: serverRequest)
      )
    }
  }

  private static func failConnection(
    _ error: Error,
    state: CodexAppServerConnectionState,
    notificationChannel: CodexAppServerAsyncThrowingChannel<
      CodexAppServerProtocol.Stable.ServerNotification
    >,
    typedServerRequestChannel: CodexAppServerAsyncThrowingChannel<CodexAppServerTypedServerRequest>
  ) async {
    let pendingResponses = await state.close(error: error)
    for pendingResponse in pendingResponses {
      pendingResponse.fail(error)
    }
    notificationChannel.finish(throwing: error)
    typedServerRequestChannel.finish(throwing: error)
  }

  private static func encodeStableLine(_ value: some Encodable) throws -> String {
    do {
      return try CodexAppServerConnectionFoundation.encodeLine(value)
    } catch {
      throw CodexAppServerClientError.malformedOutbound(error.localizedDescription)
    }
  }

  private static func decodeStableLine<T: Decodable>(_ type: T.Type, from line: String) throws -> T
  {
    try JSONDecoder().decode(type, from: Data(line.utf8))
  }

  static func encodeStableJSONValue<T: Encodable>(
    _ value: T
  ) throws -> CodexAppServerProtocol.Stable.JSONValue {
    do {
      let data = try JSONEncoder().encode(value)
      return try JSONDecoder().decode(CodexAppServerProtocol.Stable.JSONValue.self, from: data)
    } catch {
      throw CodexAppServerClientError.malformedOutbound(error.localizedDescription)
    }
  }

  private static func decodeStableJSONValue<T: Decodable>(
    _ value: CodexAppServerConnectionFoundation.JSONValue,
    as type: T.Type
  ) throws -> T {
    do {
      let data = try JSONEncoder().encode(value)
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw CodexAppServerClientError.responseDecodeFailure(error.localizedDescription)
    }
  }

  private static func envelopeKeys(
    _ envelope: CodexAppServerConnectionFoundation.RawEnvelope
  ) -> String {
    var keys: [String] = []
    if envelope.jsonrpc != nil { keys.append("jsonrpc") }
    if envelope.id != nil { keys.append("id") }
    if envelope.method != nil { keys.append("method") }
    if envelope.params != nil { keys.append("params") }
    if envelope.result != nil { keys.append("result") }
    if envelope.error != nil { keys.append("error") }
    return keys.joined(separator: ",")
  }

  private static func stableRequestID(
    _ requestID: CodexAppServerConnectionFoundation.RequestID
  ) -> CodexAppServerProtocol.Stable.RequestId {
    switch requestID {
    case .string(let value):
      return .requestidoption1(value)
    case .integer(let value):
      return .requestidoption2(value)
    }
  }

  static func runtimeRequestID(
    _ requestID: CodexAppServerProtocol.Stable.RequestId
  ) -> CodexAppServerConnectionFoundation.RequestID {
    switch requestID {
    case .requestidoption1(let value):
      return .string(value)
    case .requestidoption2(let value):
      return .integer(value)
    }
  }

  static func mapRuntimeStateError<T>(
    _ operation: () async throws -> T
  ) async throws -> T {
    do {
      return try await operation()
    } catch let error as CodexAppServerConnectionStateError {
      throw clientError(for: error)
    }
  }

  static func clientError(
    for error: CodexAppServerConnectionStateError
  ) -> CodexAppServerClientError {
    switch error {
    case .closed:
      return .closed
    case .duplicatePendingResponse:
      return .malformedOutbound("duplicate request id")
    case .duplicateServerRequest(let id):
      return .duplicateServerRequest(id: stableRequestID(id))
    case .serverRequestAlreadyCompleted(let id):
      return .serverRequestAlreadyCompleted(id: stableRequestID(id))
    }
  }

  private static func stableJSONValue(
    _ value: CodexAppServerConnectionFoundation.JSONValue
  ) -> CodexAppServerProtocol.Stable.JSONValue {
    switch value {
    case .null:
      return .null
    case .bool(let value):
      return .bool(value)
    case .number(let value):
      return .number(stableJSONNumber(value))
    case .string(let value):
      return .string(value)
    case .array(let value):
      return .array(value.map(stableJSONValue))
    case .object(let value):
      return .object(value.mapValues(stableJSONValue))
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
