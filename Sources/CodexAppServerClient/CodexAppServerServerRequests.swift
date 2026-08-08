import CodexAppServerProtocol
import CodexAppServerRuntime

package struct CodexAppServerServerRequest: Equatable, Sendable {
  package let id: CodexAppServerProtocol.Stable.RequestId
  package let request: CodexAppServerProtocol.Stable.ServerRequest

  package init(request: CodexAppServerProtocol.Stable.ServerRequest) {
    self.request = request
    self.id = request.codexAppServerRequestID
  }
}

public struct CodexAppServerServerRequestHandle<
  Params: Sendable,
  Response: Encodable & Sendable
>: Sendable {
  public let id: CodexAppServerProtocol.Stable.RequestId
  public let params: Params
  package let rawRequest: CodexAppServerServerRequest

  init(rawRequest: CodexAppServerServerRequest, params: Params) {
    self.id = rawRequest.id
    self.params = params
    self.rawRequest = rawRequest
  }
}

public enum CodexAppServerTypedServerRequest: Sendable {
  public typealias Stable = CodexAppServerProtocol.Stable

  case commandExecutionApproval(
    CodexAppServerServerRequestHandle<
      Stable.CommandExecutionRequestApprovalParams,
      Stable.CommandExecutionRequestApprovalResponse
    >
  )
  case fileChangeApproval(
    CodexAppServerServerRequestHandle<
      Stable.FileChangeRequestApprovalParams,
      Stable.FileChangeRequestApprovalResponse
    >
  )
  case toolRequestUserInput(
    CodexAppServerServerRequestHandle<
      Stable.ToolRequestUserInputParams,
      Stable.ToolRequestUserInputResponse
    >
  )
  case mcpServerElicitation(
    CodexAppServerServerRequestHandle<
      Stable.McpServerElicitationRequestParams,
      Stable.McpServerElicitationRequestResponse
    >
  )
  case permissionsApproval(
    CodexAppServerServerRequestHandle<
      Stable.PermissionsRequestApprovalParams,
      Stable.PermissionsRequestApprovalResponse
    >
  )
  case dynamicToolCall(
    CodexAppServerServerRequestHandle<
      Stable.DynamicToolCallParams,
      Stable.DynamicToolCallResponse
    >
  )
  case chatgptAuthTokensRefresh(
    CodexAppServerServerRequestHandle<
      Stable.ChatgptAuthTokensRefreshParams,
      Stable.ChatgptAuthTokensRefreshResponse
    >
  )
  case applyPatchApproval(
    CodexAppServerServerRequestHandle<
      Stable.ApplyPatchApprovalParams,
      Stable.ApplyPatchApprovalResponse
    >
  )
  case execCommandApproval(
    CodexAppServerServerRequestHandle<
      Stable.ExecCommandApprovalParams,
      Stable.ExecCommandApprovalResponse
    >
  )
  case attestationGenerate(
    CodexAppServerServerRequestHandle<
      Stable.AttestationGenerateParams,
      Stable.AttestationGenerateResponse
    >
  )

  public var id: CodexAppServerProtocol.Stable.RequestId {
    switch self {
    case .commandExecutionApproval(let handle):
      return handle.id
    case .fileChangeApproval(let handle):
      return handle.id
    case .toolRequestUserInput(let handle):
      return handle.id
    case .mcpServerElicitation(let handle):
      return handle.id
    case .permissionsApproval(let handle):
      return handle.id
    case .dynamicToolCall(let handle):
      return handle.id
    case .chatgptAuthTokensRefresh(let handle):
      return handle.id
    case .applyPatchApproval(let handle):
      return handle.id
    case .execCommandApproval(let handle):
      return handle.id
    case .attestationGenerate(let handle):
      return handle.id
    }
  }

  init(serverRequest: CodexAppServerServerRequest) {
    switch serverRequest.request {
    case .itemCommandExecutionRequestApprovalRequest(let value):
      self = .commandExecutionApproval(.init(rawRequest: serverRequest, params: value.params))
    case .itemFileChangeRequestApprovalRequest(let value):
      self = .fileChangeApproval(.init(rawRequest: serverRequest, params: value.params))
    case .itemToolRequestUserInputRequest(let value):
      self = .toolRequestUserInput(.init(rawRequest: serverRequest, params: value.params))
    case .mcpserverElicitationRequestRequest(let value):
      self = .mcpServerElicitation(.init(rawRequest: serverRequest, params: value.params))
    case .itemPermissionsRequestApprovalRequest(let value):
      self = .permissionsApproval(.init(rawRequest: serverRequest, params: value.params))
    case .itemToolCallRequest(let value):
      self = .dynamicToolCall(.init(rawRequest: serverRequest, params: value.params))
    case .accountChatgptAuthTokensRefreshRequest(let value):
      self = .chatgptAuthTokensRefresh(.init(rawRequest: serverRequest, params: value.params))
    case .applypatchapprovalrequest(let value):
      self = .applyPatchApproval(.init(rawRequest: serverRequest, params: value.params))
    case .execcommandapprovalrequest(let value):
      self = .execCommandApproval(.init(rawRequest: serverRequest, params: value.params))
    case .attestationGenerateRequest(let value):
      self = .attestationGenerate(.init(rawRequest: serverRequest, params: value.params))
    }
  }
}

extension CodexAppServerConnection {
  package func resolveServerRequest<Response: Encodable & Sendable>(
    _ serverRequest: CodexAppServerServerRequest,
    with response: Response
  ) async throws {
    try await Self.mapRuntimeStateError {
      try await state.completeServerRequest(id: Self.runtimeRequestID(serverRequest.id))
    }
    let rpcResponse = CodexAppServerProtocol.Stable.JSONRPCResponse(
      id: serverRequest.id,
      result: try Self.encodeStableJSONValue(response)
    )

    try await sendStableMessage(rpcResponse)
  }

  package func rejectServerRequest(
    _ serverRequest: CodexAppServerServerRequest,
    code: Int64,
    message: String,
    data: CodexAppServerProtocol.Stable.JSONValue? = nil
  ) async throws {
    try await Self.mapRuntimeStateError {
      try await state.completeServerRequest(id: Self.runtimeRequestID(serverRequest.id))
    }
    let rpcError = CodexAppServerProtocol.Stable.JSONRPCError(
      error: .init(code: code, data: data, message: message),
      id: serverRequest.id
    )

    try await sendStableMessage(rpcError)
  }

  public func resolveServerRequest<Params: Sendable, Response: Encodable & Sendable>(
    _ serverRequest: CodexAppServerServerRequestHandle<Params, Response>,
    with response: Response
  ) async throws {
    try await resolveServerRequest(serverRequest.rawRequest, with: response)
  }

  public func rejectServerRequest<Params: Sendable, Response: Encodable & Sendable>(
    _ serverRequest: CodexAppServerServerRequestHandle<Params, Response>,
    code: Int64,
    message: String,
    data: CodexAppServerProtocol.Stable.JSONValue? = nil
  ) async throws {
    try await rejectServerRequest(
      serverRequest.rawRequest,
      code: code,
      message: message,
      data: data
    )
  }
}

extension CodexAppServerProtocol.Stable.ServerRequest {
  fileprivate var codexAppServerRequestID: CodexAppServerProtocol.Stable.RequestId {
    switch self {
    case .itemCommandExecutionRequestApprovalRequest(let value):
      return value.id
    case .itemFileChangeRequestApprovalRequest(let value):
      return value.id
    case .itemToolRequestUserInputRequest(let value):
      return value.id
    case .mcpserverElicitationRequestRequest(let value):
      return value.id
    case .itemPermissionsRequestApprovalRequest(let value):
      return value.id
    case .itemToolCallRequest(let value):
      return value.id
    case .accountChatgptAuthTokensRefreshRequest(let value):
      return value.id
    case .applypatchapprovalrequest(let value):
      return value.id
    case .execcommandapprovalrequest(let value):
      return value.id
    case .attestationGenerateRequest(let value):
      return value.id
    }
  }
}
