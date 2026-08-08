import Foundation

/// JSON-compatible value used at Codex MCP public boundaries.
public enum CodexMCPJSONValue: Codable, Equatable, Sendable {
  case object([String: CodexMCPJSONValue])
  case array([CodexMCPJSONValue])
  case string(String)
  /// An exact signed 64-bit JSON integer.
  case integer(Int64)
  /// A finite JSON floating-point number.
  case double(Double)
  case bool(Bool)
  case null

  /// Decodes any JSON value into the public dynamic representation.
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()

    if container.decodeNil() {
      self = .null
      return
    }

    if let object = try? container.decode([String: CodexMCPJSONValue].self) {
      self = .object(object)
      return
    }

    if let array = try? container.decode([CodexMCPJSONValue].self) {
      self = .array(array)
      return
    }

    if let string = try? container.decode(String.self) {
      self = .string(string)
      return
    }

    if let bool = try? container.decode(Bool.self) {
      self = .bool(bool)
      return
    }

    if let integer = try? container.decode(Int64.self) {
      self = .integer(integer)
      return
    }

    if let number = try? container.decode(Double.self), number.isFinite {
      self = .double(number)
      return
    }

    throw DecodingError.typeMismatch(
      CodexMCPJSONValue.self,
      .init(
        codingPath: decoder.codingPath,
        debugDescription: "Unsupported JSON value.",
      ),
    )
  }

  /// Encodes the public dynamic representation as JSON.
  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()

    switch self {
    case .object(let object):
      try container.encode(object)
    case .array(let array):
      try container.encode(array)
    case .string(let string):
      try container.encode(string)
    case .integer(let integer):
      try container.encode(integer)
    case .double(let number):
      try container.encode(number)
    case .bool(let bool):
      try container.encode(bool)
    case .null:
      try container.encodeNil()
    }
  }
}

extension CodexMCPJSONValue {
  internal var objectValue: [String: CodexMCPJSONValue]? {
    guard case .object(let object) = self else {
      return nil
    }

    return object
  }

  internal var arrayValue: [CodexMCPJSONValue]? {
    guard case .array(let array) = self else {
      return nil
    }

    return array
  }

  internal var stringValue: String? {
    guard case .string(let string) = self else {
      return nil
    }

    return string
  }

  internal var boolValue: Bool? {
    guard case .bool(let bool) = self else {
      return nil
    }

    return bool
  }
}
