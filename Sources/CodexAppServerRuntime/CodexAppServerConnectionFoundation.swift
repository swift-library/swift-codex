import Foundation

/// Raw connection foundations that are independent of generated Codex
/// AppServer protocol models.
public enum CodexAppServerConnectionFoundation {
  public enum FoundationError: Error, Equatable, Sendable {
    case embeddedNewline
    case invalidUTF8
    case invalidJSON(String)
    case invalidEnvelope
  }

  public struct StdioFrameCodec: Sendable {
    private var bufferedBytes = Data()

    public init() {}

    public var hasPendingPartialLine: Bool {
      !bufferedBytes.isEmpty
    }

    public mutating func appendIncoming(_ chunk: Data) throws -> [String] {
      bufferedBytes.append(chunk)

      var lines: [String] = []
      while let newlineIndex = bufferedBytes.firstIndex(of: 0x0A) {
        var lineBytes = bufferedBytes[..<newlineIndex]
        bufferedBytes.removeSubrange(...newlineIndex)

        if lineBytes.last == 0x0D {
          lineBytes = lineBytes.dropLast()
        }

        guard let line = String(data: lineBytes, encoding: .utf8) else {
          throw FoundationError.invalidUTF8
        }

        lines.append(line)
      }

      return lines
    }

    public func encodeOutgoingLine(_ line: String) throws -> Data {
      guard !line.contains("\n") else {
        throw FoundationError.embeddedNewline
      }

      return Data((line + "\n").utf8)
    }
  }

  public enum RequestID: Equatable, Hashable, Sendable {
    case string(String)
    case integer(Int64)
  }

  public indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(JSONNumber)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
  }

  public enum JSONNumber: Equatable, Sendable, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral
  {
    public typealias IntegerLiteralType = Int64
    public typealias FloatLiteralType = Double

    case integer(Int64)
    case decimal(Decimal)

    public init(integerLiteral value: Int64) {
      self = .integer(value)
    }

    public init(floatLiteral value: Double) {
      self = .decimal(Decimal(value))
    }
  }

  public struct JSONRPCErrorBody: Codable, Equatable, Sendable {
    public let code: Int64
    public let message: String
    public let data: JSONValue?

    public init(code: Int64, message: String, data: JSONValue? = nil) {
      self.code = code
      self.message = message
      self.data = data
    }
  }

  public struct RawEnvelope: Equatable, Sendable {
    public let jsonrpc: String?
    public let id: RequestID?
    public let method: String?
    public let params: JSONValue?
    public let result: JSONValue?
    public let error: JSONRPCErrorBody?

    public init(
      jsonrpc: String? = nil,
      id: RequestID? = nil,
      method: String? = nil,
      params: JSONValue? = nil,
      result: JSONValue? = nil,
      error: JSONRPCErrorBody? = nil
    ) {
      self.jsonrpc = jsonrpc
      self.id = id
      self.method = method
      self.params = params
      self.result = result
      self.error = error
    }

    public func classify() throws -> RawMessage {
      if let jsonrpc, jsonrpc != "2.0" {
        throw FoundationError.invalidEnvelope
      }

      if let method {
        guard result == nil, error == nil else {
          throw FoundationError.invalidEnvelope
        }

        if let id {
          return .request(id: id, method: method, params: params)
        }

        return .notification(method: method, params: params)
      }

      guard result == nil || error == nil else {
        throw FoundationError.invalidEnvelope
      }

      if let result {
        guard let id else {
          throw FoundationError.invalidEnvelope
        }

        return .success(id: id, result: result)
      }

      if let error {
        return .failure(id: id, error: error)
      }

      throw FoundationError.invalidEnvelope
    }
  }

  public enum RawMessage: Equatable, Sendable {
    case request(id: RequestID, method: String, params: JSONValue?)
    case notification(method: String, params: JSONValue?)
    case success(id: RequestID, result: JSONValue?)
    case failure(id: RequestID?, error: JSONRPCErrorBody)
  }

  public static func decodeLine(_ line: String) throws -> RawEnvelope {
    guard let data = line.data(using: .utf8) else {
      throw FoundationError.invalidUTF8
    }

    do {
      return try JSONDecoder().decode(RawEnvelope.self, from: data)
    } catch {
      throw FoundationError.invalidJSON(error.localizedDescription)
    }
  }

  public static func encodeLine<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    let data: Data
    do {
      data = try encoder.encode(value)
    } catch {
      throw FoundationError.invalidJSON(error.localizedDescription)
    }

    guard let line = String(data: data, encoding: .utf8) else {
      throw FoundationError.invalidUTF8
    }

    guard !line.contains("\n") else {
      throw FoundationError.embeddedNewline
    }

    return line
  }
}

extension CodexAppServerConnectionFoundation.RequestID: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()

    if let integer = try? container.decode(Int64.self) {
      self = .integer(integer)
      return
    }

    if let string = try? container.decode(String.self) {
      self = .string(string)
      return
    }

    throw DecodingError.dataCorruptedError(
      in: container,
      debugDescription: "JSON-RPC request id must be a string or integer."
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()

    switch self {
    case .string(let string):
      try container.encode(string)
    case .integer(let integer):
      try container.encode(integer)
    }
  }
}

extension CodexAppServerConnectionFoundation.JSONRPCErrorBody {
  private enum CodingKeys: String, CodingKey {
    case code
    case message
    case data
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init(
      code: try container.decode(Int64.self, forKey: .code),
      message: try container.decode(String.self, forKey: .message),
      data: try Self.decodeDataIfPresent(container)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    try container.encode(code, forKey: .code)
    try container.encode(message, forKey: .message)
    if let data {
      try container.encode(data, forKey: .data)
    }
  }

  private static func decodeDataIfPresent(
    _ container: KeyedDecodingContainer<CodingKeys>
  ) throws -> CodexAppServerConnectionFoundation.JSONValue? {
    guard container.contains(.data) else {
      return nil
    }

    return try container.decode(
      CodexAppServerConnectionFoundation.JSONValue.self,
      forKey: .data
    )
  }
}

extension CodexAppServerConnectionFoundation.JSONValue: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()

    if container.decodeNil() {
      self = .null
      return
    }

    if let bool = try? container.decode(Bool.self) {
      self = .bool(bool)
      return
    }

    if let integer = try? container.decode(Int64.self) {
      self = .number(.integer(integer))
      return
    }

    if let decimal = try? container.decode(Decimal.self) {
      self = .number(.decimal(decimal))
      return
    }

    if let string = try? container.decode(String.self) {
      self = .string(string)
      return
    }

    if let array = try? container.decode([Self].self) {
      self = .array(array)
      return
    }

    if let object = try? container.decode([String: Self].self) {
      self = .object(object)
      return
    }

    throw DecodingError.dataCorruptedError(
      in: container,
      debugDescription: "Unsupported JSON value."
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()

    switch self {
    case .null:
      try container.encodeNil()
    case .bool(let value):
      try container.encode(value)
    case .number(.integer(let value)):
      try container.encode(value)
    case .number(.decimal(let value)):
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    }
  }
}

extension CodexAppServerConnectionFoundation.RawEnvelope: Codable {
  private enum CodingKeys: String, CodingKey {
    case jsonrpc
    case id
    case method
    case params
    case result
    case error
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init(
      jsonrpc: try container.decodeIfPresent(String.self, forKey: .jsonrpc),
      id: try container.decodeIfPresent(
        CodexAppServerConnectionFoundation.RequestID.self,
        forKey: .id
      ),
      method: try container.decodeIfPresent(String.self, forKey: .method),
      params: try Self.decodeJSONValueIfPresent(container, forKey: .params),
      result: try Self.decodeJSONValueIfPresent(container, forKey: .result),
      error: try container.decodeIfPresent(
        CodexAppServerConnectionFoundation.JSONRPCErrorBody.self,
        forKey: .error
      )
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    try container.encodeIfPresent(jsonrpc, forKey: .jsonrpc)
    try container.encodeIfPresent(id, forKey: .id)
    try container.encodeIfPresent(method, forKey: .method)
    try encodeJSONValueIfPresent(params, to: &container, forKey: .params)
    try encodeJSONValueIfPresent(result, to: &container, forKey: .result)
    try container.encodeIfPresent(error, forKey: .error)
  }

  private static func decodeJSONValueIfPresent(
    _ container: KeyedDecodingContainer<CodingKeys>,
    forKey key: CodingKeys
  ) throws -> CodexAppServerConnectionFoundation.JSONValue? {
    guard container.contains(key) else {
      return nil
    }

    return try container.decode(
      CodexAppServerConnectionFoundation.JSONValue.self,
      forKey: key
    )
  }

  private func encodeJSONValueIfPresent(
    _ value: CodexAppServerConnectionFoundation.JSONValue?,
    to container: inout KeyedEncodingContainer<CodingKeys>,
    forKey key: CodingKeys
  ) throws {
    if let value {
      try container.encode(value, forKey: key)
    }
  }
}
