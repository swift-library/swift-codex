import Foundation

struct MappedType {
  let typeName: String
  let isOptional: Bool
  let nestedDeclarations: [String]
}

struct ObjectProperty {
  let name: String
  let typeName: String
  let hasDefaultNil: Bool
}

enum UnionBranch {
  case stringLiteral(caseName: String, rawValue: String)
  case payload(caseName: String, typeName: String)

  var caseDeclaration: String {
    switch self {
    case .stringLiteral(let caseName, _):
      return "case \(caseName)"
    case .payload(let caseName, let typeName):
      return "case \(caseName)(\(typeName))"
    }
  }

  var isStringLiteral: Bool {
    if case .stringLiteral = self {
      return true
    }
    return false
  }
}

enum SchemaNode {
  static func object(_ value: Any) throws -> [String: Any] {
    guard let object = value as? [String: Any] else {
      throw GeneratorError.invalidSchema("expected schema object")
    }
    return object
  }
}

enum SwiftNames {
  private static let reserved: Set<String> = [
    "associatedtype", "class", "deinit", "enum", "extension", "fileprivate",
    "func", "import", "init", "inout", "internal", "let", "open", "operator",
    "private", "precedencegroup", "protocol", "public", "rethrows", "static",
    "struct", "subscript", "typealias", "var", "break", "case", "catch",
    "continue", "default", "defer", "do", "else", "fallthrough", "for",
    "guard", "if", "in", "repeat", "return", "throw", "switch", "where",
    "while", "as", "Any", "Type", "false", "is", "nil", "self", "Self", "super",
    "true",
  ]

  static func referenceName(_ reference: String) -> String {
    reference.components(separatedBy: "/").last ?? reference
  }

  static func type(_ raw: String) -> String {
    let words = splitWords(raw)
    let name = words.map { capitalize($0) }.joined()
    return validIdentifier(name.isEmpty ? "Value" : name, fallback: "Value")
  }

  static func property(_ raw: String, used: inout Set<String>) -> String {
    var name: String
    if raw.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil,
      !reserved.contains(raw),
      !raw.hasPrefix("$")
    {
      name = raw
    } else {
      let words = splitWords(raw)
      name = lowerCamel(words)
      if reserved.contains(name) {
        name += "Value"
      }
    }

    name = validIdentifier(name, fallback: "value")
    return makeUnique(name, used: &used)
  }

  static func method(_ raw: String, used: inout Set<String>) -> String {
    let words = splitWords(raw)
    guard let first = words.first else {
      return makeUnique("method", used: &used)
    }

    let name = lowerFirst(first) + words.dropFirst().map { capitalize($0) }.joined()
    return makeUnique(validIdentifier(name, fallback: "method"), used: &used)
  }

  static func enumCase(_ raw: String, used: inout Set<String>) -> String {
    let words = splitWords(raw)
    var name = lowerCamel(words)
    if name.isEmpty {
      name = "value"
    }
    if name.first?.isNumber == true {
      name = "value" + capitalize(name)
    }
    if reserved.contains(name) {
      name += "Value"
    }
    name = validIdentifier(name, fallback: "value")
    return makeUnique(name, used: &used)
  }

  static func stringLiteral(_ value: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: [value], options: [])
    if let data,
      let encoded = String(data: data, encoding: .utf8),
      encoded.count >= 2
    {
      return String(encoded.dropFirst().dropLast())
        .replacingOccurrences(of: #"\/"#, with: "/")
    }
    return "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
  }

  private static func splitWords(_ raw: String) -> [String] {
    let scalars = raw.unicodeScalars.map {
      CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
    }
    return String(scalars).split(separator: " ").map(String.init)
  }

  private static func lowerCamel(_ words: [String]) -> String {
    guard let first = words.first else {
      return ""
    }
    return first.lowercased() + words.dropFirst().map { capitalize($0) }.joined()
  }

  private static func capitalize(_ value: String) -> String {
    guard let first = value.first else {
      return value
    }
    return String(first).uppercased() + String(value.dropFirst())
  }

  private static func lowerFirst(_ value: String) -> String {
    guard let first = value.first else {
      return value
    }
    return String(first).lowercased() + String(value.dropFirst())
  }

  private static func validIdentifier(_ value: String, fallback: String) -> String {
    var result = value.filter { $0.isLetter || $0.isNumber || $0 == "_" }
    if result.isEmpty {
      result = fallback
    }
    if result.first?.isNumber == true {
      result = fallback + capitalize(result)
    }
    return reserved.contains(result) ? result + "Value" : result
  }

  private static func makeUnique(_ value: String, used: inout Set<String>) -> String {
    if used.insert(value).inserted {
      return value
    }
    var index = 2
    while true {
      let candidate = "\(value)\(index)"
      if used.insert(candidate).inserted {
        return candidate
      }
      index += 1
    }
  }
}

extension Surface {
  var generatedNamespace: String {
    switch self {
    case .stable:
      return "CodexAppServerProtocol.Stable"
    case .experimental:
      return "CodexAppServerProtocol.Experimental"
    }
  }

  var namespaceName: String {
    switch self {
    case .stable:
      return "Stable"
    case .experimental:
      return "Experimental"
    }
  }
}

extension Dictionary where Key == String, Value == Any {
  func removingKeys(_ keys: Set<String>) -> [String: Any] {
    var copy = self
    for key in keys {
      copy.removeValue(forKey: key)
    }
    return copy
  }
}

extension String {
  func indented(by spaces: Int) -> String {
    let prefix = String(repeating: " ", count: spaces)
    return split(separator: "\n", omittingEmptySubsequences: false)
      .map { line in line.isEmpty ? "" : prefix + line }
      .joined(separator: "\n")
  }
}
