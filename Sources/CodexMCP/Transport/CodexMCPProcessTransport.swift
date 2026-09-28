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
  private let descriptors: CodexMCPStdioDescriptors?
  private let requestedProtocolVersion: String
  private let subprocess: CodexMCPManagedSubprocess
  private var inboundObserver: (@Sendable (Data) async throws -> Void)?
  private var closeObserver: (@Sendable (CodexMCPError) async -> Void)?
  private var closeTask: Task<Void, Never>?
  private var closeNotification: Task<Void, Never>?
  private var isConnected = false
  private var isClosed = false
  private var hasYieldedInbound = false
  private var sendObservations: [CodexMCPRequestID: AsyncThrowingStream<Void, Error>.Continuation] =
    [:]

  init(
    baseTransport: StdioTransport,
    requestedProtocolVersion: String,
    subprocess: CodexMCPManagedSubprocess,
    descriptors: CodexMCPStdioDescriptors? = nil,
    logger: Logger? = nil
  ) {
    self.baseTransport = baseTransport
    self.descriptors = descriptors
    self.requestedProtocolVersion = requestedProtocolVersion
    self.subprocess = subprocess
    self.logger = logger ?? Logger(label: "swift-codex.codexmcp.transport")
  }

  static func make(
    subprocess: CodexMCPManagedSubprocess,
    requestedProtocolVersion: String
  ) throws -> Self {
    guard let input = subprocess.output, let output = subprocess.input else {
      throw CodexMCPError.transportFailure
    }
    let descriptors = try CodexMCPStdioDescriptors(input: input, output: output)
    return Self(
      baseTransport: StdioTransport(input: descriptors.input, output: descriptors.output),
      requestedProtocolVersion: requestedProtocolVersion,
      subprocess: subprocess,
      descriptors: descriptors
    )
  }

  func setInboundObserver(_ observer: @escaping @Sendable (Data) async throws -> Void) {
    inboundObserver = observer
  }

  func setCloseObserver(_ observer: @escaping @Sendable (CodexMCPError) async -> Void) {
    closeObserver = observer
  }

  func connect() async throws {
    guard !isClosed else { throw CodexMCPError.transportFailure }
    guard !isConnected else { return }
    do {
      try await baseTransport.connect()
      guard !isClosed else {
        await baseTransport.disconnect()
        throw CodexMCPError.transportFailure
      }
      isConnected = true
      let input = CodexMCPInboundReader(await baseTransport.receive())
      let lifetime = CodexMCPReceiveLifetime { [weak self] in
        Task { [weak self] in await self?.disconnect() }
      }
      messageStream = AsyncThrowingStream(unfolding: { [weak self, input, lifetime] in
        defer { withExtendedLifetime(lifetime) {} }
        guard let self else { return nil }
        return try await self.nextInbound(from: input)
      })
    } catch {
      await disconnect()
      throw CodexMCPError.transportFailure
    }
  }

  func disconnect() async {
    if let closeTask {
      await closeTask.value
      return
    }
    isClosed = true
    isConnected = false
    for observation in sendObservations.values {
      observation.finish(throwing: CodexMCPError.transportFailure)
    }
    sendObservations.removeAll()
    let task = Task { [baseTransport] in await baseTransport.disconnect() }
    closeTask = task
    await task.value
  }

  private var messageStream: AsyncThrowingStream<Data, Error> = AsyncThrowingStream {
    continuation in
    continuation.finish()
  }

  func finishCloseNotification() async { await closeNotification?.value }

  func receive() -> AsyncThrowingStream<Data, Error> {
    messageStream
  }

  func observeRequestSend(_ requestID: CodexMCPRequestID) throws
    -> AsyncThrowingStream<Void, Error>
  {
    guard isConnected, sendObservations.count < 256, sendObservations[requestID] == nil else {
      throw CodexMCPError.transportFailure
    }
    let (stream, continuation) = AsyncThrowingStream<Void, Error>.makeStream()
    sendObservations[requestID] = continuation
    return stream
  }

  func finishRequestSend(_ requestID: CodexMCPRequestID, error: Error? = nil) {
    guard let observation = sendObservations.removeValue(forKey: requestID) else { return }
    if let error {
      observation.finish(throwing: error)
    } else {
      observation.finish()
    }
  }

  func send(_ data: Data) async throws {
    let object = try? Self.jsonObject(from: data)
    let outboundRequestID = object?["method"] != nil ? requestID(from: object?["id"]) : nil
    do {
      guard isConnected else { throw CodexMCPError.transportFailure }
      try await baseTransport.send(normalizeOutboundData(data))
      if let outboundRequestID { finishRequestSend(outboundRequestID) }
    } catch {
      if let outboundRequestID { finishRequestSend(outboundRequestID, error: error) }
      throw error
    }
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

  private func nextInbound(from input: CodexMCPInboundReader) async throws -> Data? {
    guard isConnected else { return nil }
    do {
      guard let data = try await input.next() else {
        throw await subprocessFailure(
          fallback: hasYieldedInbound ? .transportFailure : .startupFailure,
          stage: hasYieldedInbound ? .transport : .startup)
      }
      try Task.checkCancellation()
      guard isConnected else { return nil }
      hasYieldedInbound = true
      try await inboundObserver?(data)
      return isConnected ? data : nil
    } catch {
      guard isConnected else { return nil }
      let failure: CodexMCPError
      if let error = error as? CodexMCPError {
        failure = error
      } else {
        failure = await subprocessFailure(fallback: .transportFailure, stage: .transport)
      }
      await disconnect()
      if closeNotification == nil {
        // The MCP client joins its reader during disconnect. Notify outside that reader's task.
        let observer = closeObserver
        closeNotification = Task { await observer?(failure) }
      }
      throw failure
    }
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

/// The lock admits one iterator advance; no other method accesses the iterator.
/// This narrow bridge supports macOS 14's nonisolated AsyncIterator.next API.
private final class CodexMCPInboundReader: @unchecked Sendable {
  private var iterator: AsyncThrowingStream<Data, Error>.Iterator
  private let lock = NSLock()
  private var advancing = false

  init(_ stream: AsyncThrowingStream<Data, Error>) { iterator = stream.makeAsyncIterator() }

  func next() async throws -> Data? {
    try lock.withLock {
      guard !advancing else { throw CodexMCPError.transportFailure }
      advancing = true
    }
    defer { lock.withLock { advancing = false } }
    return try await iterator.next()
  }
}

/// Stream cancellation can release the producer without ever invoking its body.
private final class CodexMCPReceiveLifetime: Sendable {
  private let finish: @Sendable () -> Void
  init(_ finish: @escaping @Sendable () -> Void) { self.finish = finish }
  deinit { finish() }
}
