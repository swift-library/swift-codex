import Foundation
import Logging
import MCP

#if canImport(System)
  import System
#else
  @preconcurrency import SystemPackage
#endif

/// Target-local adapter over the SDK stdio transport for the owned `codex mcp-server` process.
internal actor CodexMCPProcessTransport: Transport {
  nonisolated let logger: Logger

  private let baseTransport: StdioTransport
  private let requestedProtocolVersion: String
  private let subprocess: CodexMCPManagedSubprocess
  private var inboundObserver: (@Sendable (Data) async -> Void)?
  private var closeObserver: (@Sendable (CodexMCPError) async -> Void)?
  private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
  private var receiveTask: Task<Void, Never>?
  private var isConnected = false
  private var hasYieldedInbound = false

  init(
    baseTransport: StdioTransport,
    requestedProtocolVersion: String,
    subprocess: CodexMCPManagedSubprocess,
    logger: Logger? = nil
  ) {
    self.baseTransport = baseTransport
    self.requestedProtocolVersion = requestedProtocolVersion
    self.subprocess = subprocess
    self.logger = logger ?? Logger(label: "swift-codex.codexmcp.transport")
  }

  static func make(
    subprocess: CodexMCPManagedSubprocess,
    requestedProtocolVersion: String
  ) throws -> Self {
    guard
      let standardInput = subprocess.standardInput,
      let standardOutput = subprocess.standardOutput
    else {
      throw CodexMCPError.transportFailure
    }

    let input = FileDescriptor(rawValue: standardOutput.fileHandleForReading.fileDescriptor)
    let output = FileDescriptor(rawValue: standardInput.fileHandleForWriting.fileDescriptor)

    return Self(
      baseTransport: StdioTransport(input: input, output: output),
      requestedProtocolVersion: requestedProtocolVersion,
      subprocess: subprocess
    )
  }

  func setInboundObserver(_ observer: @escaping @Sendable (Data) async -> Void) {
    inboundObserver = observer
  }

  func setCloseObserver(_ observer: @escaping @Sendable (CodexMCPError) async -> Void) {
    closeObserver = observer
  }

  func connect() async throws {
    guard !isConnected else {
      return
    }

    var streamContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    messageStream = AsyncThrowingStream<Data, Error> { continuation in
      streamContinuation = continuation
    }
    continuation = streamContinuation

    do {
      try await baseTransport.connect()
      isConnected = true
      receiveTask = Task { [weak self] in
        await self?.forwardInboundMessages()
      }
    } catch {
      continuation?.finish(throwing: CodexMCPError.transportFailure)
      continuation = nil
      throw CodexMCPError.transportFailure
    }
  }

  func disconnect() async {
    guard isConnected else {
      return
    }

    isConnected = false
    receiveTask?.cancel()
    receiveTask = nil
    await baseTransport.disconnect()
    continuation?.finish()
    continuation = nil
  }

  private var messageStream: AsyncThrowingStream<Data, Error> = AsyncThrowingStream {
    continuation in
    continuation.finish()
  }

  func receive() -> AsyncThrowingStream<Data, Error> {
    messageStream
  }

  func send(_ data: Data) async throws {
    guard isConnected else {
      throw CodexMCPError.transportFailure
    }

    try await baseTransport.send(normalizeOutboundData(data))
  }

  private func normalizeOutboundData(_ data: Data) throws -> Data {
    let outboundValue = translatedInitializeRequestIfNeeded(data) ?? data
    var normalized = outboundValue
    while normalized.last == 0x0A || normalized.last == 0x0D {
      normalized.removeLast()
    }
    return normalized
  }

  private func translatedInitializeRequestIfNeeded(_ data: Data) -> Data? {
    guard var envelope = try? Self.jsonObject(from: data),
      envelope["method"]?.stringValue == "initialize"
    else {
      return nil
    }

    if var params = envelope["params"]?.objectValue {
      params["protocolVersion"] = .string(requestedProtocolVersion)
      envelope["params"] = .object(params)
    }

    return try? Self.encodedData(from: .object(envelope))
  }

  private func forwardInboundMessages() async {
    do {
      let stream = await baseTransport.receive()
      for try await data in stream {
        if Task.isCancelled {
          break
        }
        await yieldInbound(data)
      }

      guard isConnected else {
        continuation?.finish()
        return
      }

      let closeError = await subprocessFailure(
        fallback: hasYieldedInbound ? .transportFailure : .startupFailure,
        stage: hasYieldedInbound ? .transport : .startup
      )
      continuation?.finish(throwing: closeError)
      await closeObserver?(closeError)
    } catch {
      guard isConnected else {
        continuation?.finish()
        return
      }

      let closeError = await subprocessFailure(fallback: .transportFailure, stage: .transport)
      continuation?.finish(throwing: closeError)
      await closeObserver?(closeError)
    }
  }

  private func yieldInbound(_ data: Data) async {
    hasYieldedInbound = true
    await inboundObserver?(data)
    continuation?.yield(data)
  }

  private func subprocessFailure(
    fallback: CodexMCPError,
    stage: CodexMCPError.ProcessFailureStage
  ) async -> CodexMCPError {
    guard let stderr = await subprocess.stderrContext(), !stderr.isEmpty else {
      return fallback
    }
    return .processFailure(stage: stage, context: .init(stderr: stderr))
  }

  private static func jsonObject(from data: Data) throws -> [String: CodexMCPJSONValue] {
    let decoded = try JSONDecoder().decode(CodexMCPJSONValue.self, from: data)
    guard case .object(let object) = decoded else {
      throw CodexMCPError.protocolFailure
    }
    return object
  }

  private static func encodedData(from value: CodexMCPJSONValue) throws -> Data {
    try JSONEncoder().encode(value)
  }
}
