import Foundation

struct CodexExecJSONDocument: Codable {
  let value: CodexExecJSONValue

  init(value: CodexExecJSONValue) {
    self.value = value
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      value = .null
    } else if let bool = try? container.decode(Bool.self) {
      value = .bool(bool)
    } else if let integer = try? container.decode(Int64.self) {
      value = .integer(integer)
    } else if let double = try? container.decode(Double.self) {
      value = .double(double)
    } else if let string = try? container.decode(String.self) {
      value = .string(string)
    } else if let array = try? container.decode([Self].self) {
      value = .array(array.map(\.value))
    } else {
      value = .object(try container.decode([String: Self].self).mapValues(\.value))
    }
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch value {
    case .null:
      try container.encodeNil()
    case .bool(let bool):
      try container.encode(bool)
    case .integer(let integer):
      try container.encode(integer)
    case .double(let double):
      try container.encode(double)
    case .string(let string):
      try container.encode(string)
    case .array(let array):
      try container.encode(array.map(Self.init(value:)))
    case .object(let object):
      try container.encode(object.mapValues(Self.init(value:)))
    }
  }
}
