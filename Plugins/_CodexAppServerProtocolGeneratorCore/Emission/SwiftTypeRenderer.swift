struct TypeContext {
  let knownTypeNames: Set<String>
}

struct SwiftTypeRenderer {
  let context: TypeContext

  func declaration(
    name: String,
    schema: [String: Any],
    nestedDefinitions: [String: Any] = [:]
  ) throws -> String {
    if let enumValues = schema["enum"] as? [String] {
      return enumDeclaration(name: name, values: enumValues, nestedDeclarations: [])
    }

    if let typeAlias = try typeAliasDeclaration(name: name, schema: schema) {
      return typeAlias
    }

    if let branches = schema["oneOf"] as? [Any] {
      return try unionDeclaration(
        name: name, branches: branches, nestedDefinitions: nestedDefinitions)
    }

    if let branches = schema["anyOf"] as? [Any] {
      if let optional = optionalBranch(from: branches) {
        let mapped = try typeReference(
          schema: optional,
          suggestedName: name + "Value",
          optionalContext: false
        )
        return "public typealias \(name) = \(mapped.typeName)?"
      }
      return try unionDeclaration(
        name: name, branches: branches, nestedDefinitions: nestedDefinitions)
    }

    if let branches = schema["allOf"] as? [Any], branches.count == 1 {
      let mapped = try typeReference(
        schema: branches[0],
        suggestedName: name + "Value",
        optionalContext: false
      )
      return "public typealias \(name) = \(mapped.typeName)"
    }

    if isObjectSchema(schema) {
      return try objectDeclaration(name: name, schema: schema, nestedDefinitions: nestedDefinitions)
    }

    throw GeneratorError.invalidSchema("cannot emit Swift declaration for \(name)")
  }

  private func typeAliasDeclaration(name: String, schema: [String: Any]) throws -> String? {
    if schema["properties"] != nil || schema["oneOf"] != nil || schema["anyOf"] != nil {
      return nil
    }
    guard let mapped = try simpleTypeReference(schema: schema, suggestedName: name + "Value") else {
      return nil
    }
    return "public typealias \(name) = \(mapped.typeName)"
  }

  private func objectDeclaration(
    name: String,
    schema: [String: Any],
    nestedDefinitions: [String: Any]
  ) throws -> String {
    let properties = (schema["properties"] as? [String: Any]) ?? [:]
    if properties.isEmpty,
      let dictionary = try dictionaryType(schema: schema, suggestedName: name + "Value")
    {
      return "public typealias \(name) = \(dictionary)"
    }

    let required = Set((schema["required"] as? [String]) ?? [])
    var nested: [String] = []
    var propertyModels: [ObjectProperty] = []
    var codingCases: [String] = []
    var usedPropertyNames = Set<String>()

    for rawName in properties.keys.sorted() {
      guard let propertySchema = properties[rawName] else {
        continue
      }
      let swiftName = SwiftNames.property(rawName, used: &usedPropertyNames)
      let suggestedType = SwiftNames.type(rawName)
      let mapped = try typeReference(
        schema: propertySchema,
        suggestedName: suggestedType.isEmpty ? "Value" : suggestedType,
        optionalContext: !required.contains(rawName)
      )
      nested.append(contentsOf: mapped.nestedDeclarations)
      let isOptional = mapped.isOptional || !required.contains(rawName)
      propertyModels.append(
        ObjectProperty(
          name: swiftName,
          typeName: "\(mapped.typeName)\(isOptional ? "?" : "")",
          hasDefaultNil: isOptional
        ))
      codingCases.append("case \(swiftName) = \(SwiftNames.stringLiteral(rawName))")
    }

    for nestedDefinitionName in nestedDefinitions.keys.sorted() {
      guard let nestedSchema = nestedDefinitions[nestedDefinitionName] as? [String: Any] else {
        continue
      }
      nested.append(
        try declaration(
          name: SwiftNames.type(nestedDefinitionName),
          schema: nestedSchema.removingKeys(["title"]),
          nestedDefinitions: [:]
        ))
    }

    var lines: [String] = ["public struct \(name): Codable, Equatable, Sendable {"]
    if propertyModels.isEmpty {
      lines.append("  public init() {}")
    } else {
      lines.append(contentsOf: propertyModels.map { "  public let \($0.name): \($0.typeName)" })
      lines.append("")
      lines.append(contentsOf: memberwiseInitializerLines(for: propertyModels).map { "  \($0)" })
    }
    if !codingCases.isEmpty {
      lines.append("")
      lines.append("  private enum CodingKeys: String, CodingKey {")
      lines.append(contentsOf: codingCases.map { "    \($0)" })
      lines.append("  }")
    }
    if !nested.isEmpty {
      lines.append("")
      lines.append(contentsOf: nested.map { $0.indented(by: 2) })
    }
    lines.append("}")
    return lines.joined(separator: "\n")
  }

  private func memberwiseInitializerLines(for properties: [ObjectProperty]) -> [String] {
    var lines = ["public init("]
    for (index, property) in properties.enumerated() {
      let suffix = index == properties.count - 1 ? "" : ","
      let defaultValue = property.hasDefaultNil ? " = nil" : ""
      lines.append("  \(property.name): \(property.typeName)\(defaultValue)\(suffix)")
    }
    lines.append(") {")
    for property in properties {
      lines.append("  self.\(property.name) = \(property.name)")
    }
    lines.append("}")
    return lines
  }

  private func unionDeclaration(
    name: String,
    branches: [Any],
    nestedDefinitions: [String: Any]
  ) throws -> String {
    if let rawValues = stringOnlyUnionValues(branches) {
      return enumDeclaration(name: name, values: rawValues, nestedDeclarations: [])
    }

    var branchModels: [UnionBranch] = []
    var nested: [String] = []
    var usedCases = Set<String>()

    for (index, branch) in branches.enumerated() {
      let branchSchema = try SchemaNode.object(branch)
      if let enumValues = branchSchema["enum"] as? [String] {
        for value in enumValues {
          branchModels.append(
            .stringLiteral(
              caseName: SwiftNames.enumCase(value, used: &usedCases),
              rawValue: value
            ))
        }
        continue
      }

      let branchName = branchTypeName(
        schema: branchSchema,
        fallback: "\(name)Option\(index + 1)",
        reservedNames: Set(nestedDefinitions.keys.map(SwiftNames.type))
      )
      let caseName = SwiftNames.enumCase(
        branchCaseSeed(schema: branchSchema, fallback: branchName), used: &usedCases)
      let mapped = try typeReference(
        schema: branchSchema,
        suggestedName: branchName,
        optionalContext: false
      )
      nested.append(contentsOf: mapped.nestedDeclarations)
      branchModels.append(.payload(caseName: caseName, typeName: mapped.typeName))
    }

    for nestedDefinitionName in nestedDefinitions.keys.sorted() {
      guard let nestedSchema = nestedDefinitions[nestedDefinitionName] as? [String: Any] else {
        continue
      }
      nested.append(
        try declaration(
          name: SwiftNames.type(nestedDefinitionName),
          schema: nestedSchema.removingKeys(["title"]),
          nestedDefinitions: [:]
        ))
    }

    var lines: [String] = ["public enum \(name): Codable, Equatable, Sendable {"]
    for branch in branchModels {
      lines.append("  \(branch.caseDeclaration)")
    }
    if !nested.isEmpty {
      lines.append("")
      lines.append(contentsOf: nested.map { $0.indented(by: 2) })
    }
    lines.append("")
    lines.append("  public init(from decoder: Decoder) throws {")
    if branchModels.contains(where: \.isStringLiteral) {
      lines.append("    let container = try decoder.singleValueContainer()")
      lines.append("    if let value = try? container.decode(String.self) {")
      lines.append("      switch value {")
      for branch in branchModels {
        if case .stringLiteral(let caseName, let rawValue) = branch {
          lines.append("      case \(SwiftNames.stringLiteral(rawValue)):")
          lines.append("        self = .\(caseName)")
          lines.append("        return")
        }
      }
      lines.append("      default:")
      lines.append("        break")
      lines.append("      }")
      lines.append("    }")
    }
    for branch in branchModels {
      if case .payload(let caseName, let typeName) = branch {
        lines.append("    if let value = try? \(typeName)(from: decoder) {")
        lines.append("      self = .\(caseName)(value)")
        lines.append("      return")
        lines.append("    }")
      }
    }
    lines.append("    throw DecodingError.dataCorrupted(")
    lines.append("      DecodingError.Context(")
    lines.append("        codingPath: decoder.codingPath,")
    lines.append("        debugDescription: \"Value did not match any \(name) variant.\"")
    lines.append("      )")
    lines.append("    )")
    lines.append("  }")
    lines.append("")
    lines.append("  public func encode(to encoder: Encoder) throws {")
    lines.append("    switch self {")
    for branch in branchModels {
      switch branch {
      case .stringLiteral(let caseName, let rawValue):
        lines.append("    case .\(caseName):")
        lines.append("      var container = encoder.singleValueContainer()")
        lines.append("      try container.encode(\(SwiftNames.stringLiteral(rawValue)))")
      case .payload(let caseName, _):
        lines.append("    case let .\(caseName)(value):")
        lines.append("      try value.encode(to: encoder)")
      }
    }
    lines.append("    }")
    lines.append("  }")
    lines.append("}")
    return lines.joined(separator: "\n")
  }

  private func enumDeclaration(name: String, values: [String], nestedDeclarations: [String])
    -> String
  {
    var used = Set<String>()
    var lines: [String] = ["public enum \(name): String, Codable, Equatable, Sendable {"]
    for value in values {
      lines.append(
        "  case \(SwiftNames.enumCase(value, used: &used)) = \(SwiftNames.stringLiteral(value))")
    }
    if !nestedDeclarations.isEmpty {
      lines.append("")
      lines.append(contentsOf: nestedDeclarations.map { $0.indented(by: 2) })
    }
    lines.append("}")
    return lines.joined(separator: "\n")
  }

  private func typeReference(
    schema rawSchema: Any,
    suggestedName: String,
    optionalContext: Bool
  ) throws -> MappedType {
    guard let schema = rawSchema as? [String: Any] else {
      if let bool = rawSchema as? Bool, bool {
        return MappedType(typeName: "JSONValue", isOptional: false, nestedDeclarations: [])
      }
      throw GeneratorError.invalidSchema("expected schema object for \(suggestedName)")
    }

    if let optional = optionalSchema(schema) {
      let mapped = try typeReference(
        schema: optional, suggestedName: suggestedName, optionalContext: false)
      return MappedType(
        typeName: mapped.typeName,
        isOptional: true,
        nestedDeclarations: mapped.nestedDeclarations
      )
    }

    if let reference = schema["$ref"] as? String {
      return MappedType(
        typeName: SwiftNames.type(SwiftNames.referenceName(reference)), isOptional: false,
        nestedDeclarations: [])
    }

    if let branches = schema["allOf"] as? [Any], branches.count == 1 {
      return try typeReference(
        schema: branches[0], suggestedName: suggestedName, optionalContext: optionalContext)
    }

    if let mapped = try simpleTypeReference(schema: schema, suggestedName: suggestedName) {
      return mapped
    }

    if let branches = schema["anyOf"] as? [Any] {
      if let optional = optionalBranch(from: branches) {
        let mapped = try typeReference(
          schema: optional, suggestedName: suggestedName, optionalContext: false)
        return MappedType(
          typeName: mapped.typeName,
          isOptional: true,
          nestedDeclarations: mapped.nestedDeclarations
        )
      }
      let typeName = nestedTypeName(suggestedName)
      let declaration = try unionDeclaration(
        name: typeName, branches: branches, nestedDefinitions: [:])
      return MappedType(typeName: typeName, isOptional: false, nestedDeclarations: [declaration])
    }

    if let branches = schema["oneOf"] as? [Any] {
      let typeName = nestedTypeName(suggestedName)
      let declaration = try unionDeclaration(
        name: typeName, branches: branches, nestedDefinitions: [:])
      return MappedType(typeName: typeName, isOptional: false, nestedDeclarations: [declaration])
    }

    if isObjectSchema(schema) {
      if let dictionary = try dictionaryType(schema: schema, suggestedName: suggestedName) {
        return MappedType(typeName: dictionary, isOptional: false, nestedDeclarations: [])
      }
      let typeName = nestedTypeName(suggestedName)
      let declaration = try objectDeclaration(
        name: typeName, schema: schema, nestedDefinitions: [:])
      return MappedType(typeName: typeName, isOptional: false, nestedDeclarations: [declaration])
    }

    if isUnconstrainedSchema(schema) {
      return MappedType(typeName: "JSONValue", isOptional: false, nestedDeclarations: [])
    }

    throw GeneratorError.invalidSchema("cannot map schema for \(suggestedName)")
  }

  private func simpleTypeReference(schema: [String: Any], suggestedName: String) throws
    -> MappedType?
  {
    if let enumValues = schema["enum"] as? [String] {
      let typeName = nestedTypeName(suggestedName)
      return MappedType(
        typeName: typeName,
        isOptional: false,
        nestedDeclarations: [
          enumDeclaration(name: typeName, values: enumValues, nestedDeclarations: [])
        ]
      )
    }

    if let type = schema["type"] as? String {
      switch type {
      case "string":
        return MappedType(typeName: "String", isOptional: false, nestedDeclarations: [])
      case "boolean":
        return MappedType(typeName: "Bool", isOptional: false, nestedDeclarations: [])
      case "integer":
        return MappedType(
          typeName: integerType(format: schema["format"] as? String), isOptional: false,
          nestedDeclarations: [])
      case "number":
        return MappedType(typeName: "Double", isOptional: false, nestedDeclarations: [])
      case "array":
        let itemSchema = schema["items"] ?? true
        let mapped = try typeReference(
          schema: itemSchema,
          suggestedName: SwiftNames.type(suggestedName) + "Item",
          optionalContext: false
        )
        return MappedType(
          typeName: "[\(mapped.typeName)\(mapped.isOptional ? "?" : "")]",
          isOptional: false,
          nestedDeclarations: mapped.nestedDeclarations
        )
      case "object":
        return nil
      case "null":
        return MappedType(typeName: "JSONValue", isOptional: true, nestedDeclarations: [])
      default:
        throw GeneratorError.invalidSchema("unsupported JSON Schema type '\(type)'")
      }
    }

    return nil
  }

  private func dictionaryType(schema: [String: Any], suggestedName: String) throws -> String? {
    guard isObjectSchema(schema), schema["properties"] == nil else {
      return nil
    }

    guard let additionalProperties = schema["additionalProperties"] else {
      return "[String: JSONValue]"
    }

    if let allowed = additionalProperties as? Bool {
      return allowed ? "[String: JSONValue]" : nil
    }

    let mapped = try typeReference(
      schema: additionalProperties,
      suggestedName: SwiftNames.type(suggestedName) + "Value",
      optionalContext: false
    )
    return "[String: \(mapped.typeName)\(mapped.isOptional ? "?" : "")]"
  }

  private func optionalSchema(_ schema: [String: Any]) -> Any? {
    if let types = schema["type"] as? [String],
      types.contains("null"),
      let nonNull = types.first(where: { $0 != "null" })
    {
      var copy = schema
      copy["type"] = nonNull
      return copy
    }
    if let branches = schema["anyOf"] as? [Any] {
      return optionalBranch(from: branches)
    }
    return nil
  }

  private func optionalBranch(from branches: [Any]) -> Any? {
    var nonNull: Any?
    var nullCount = 0
    for branch in branches {
      if let dictionary = branch as? [String: Any],
        dictionary["type"] as? String == "null"
      {
        nullCount += 1
      } else if nonNull == nil {
        nonNull = branch
      } else {
        return nil
      }
    }
    return nullCount == 1 ? nonNull : nil
  }

  private func stringOnlyUnionValues(_ branches: [Any]) -> [String]? {
    var values: [String] = []
    for branch in branches {
      guard let schema = branch as? [String: Any],
        let enumValues = schema["enum"] as? [String]
      else {
        return nil
      }
      values.append(contentsOf: enumValues)
    }
    return values
  }

  private func branchTypeName(schema: [String: Any], fallback: String, reservedNames: Set<String>)
    -> String
  {
    let candidate: String
    if let title = schema["title"] as? String {
      candidate = SwiftNames.type(title)
    } else {
      candidate = SwiftNames.type(fallback)
    }
    return reservedNames.contains(candidate) ? candidate + "Variant" : candidate
  }

  private func branchCaseSeed(schema: [String: Any], fallback: String) -> String {
    if let properties = schema["properties"] as? [String: Any],
      let typeSchema = properties["type"] as? [String: Any],
      let values = typeSchema["enum"] as? [String],
      let first = values.first
    {
      return first
    }
    if let title = schema["title"] as? String {
      return title
    }
    if let reference = schema["$ref"] as? String {
      return SwiftNames.referenceName(reference)
    }
    return fallback
  }

  private func integerType(format: String?) -> String {
    switch format {
    case "int64":
      return "Int64"
    case "int32":
      return "Int32"
    case "uint64":
      return "UInt64"
    case "uint32":
      return "UInt32"
    case "uint16":
      return "UInt16"
    case "uint":
      return "UInt"
    default:
      return "Int"
    }
  }

  private func isObjectSchema(_ schema: [String: Any]) -> Bool {
    schema["type"] as? String == "object" || schema["properties"] != nil
      || schema["additionalProperties"] != nil
  }

  private func isUnconstrainedSchema(_ schema: [String: Any]) -> Bool {
    let nonMetadataKeys = Set(schema.keys).subtracting(["description", "default", "title"])
    return nonMetadataKeys.isEmpty
  }

  private func nestedTypeName(_ suggestedName: String) -> String {
    let candidate = SwiftNames.type(suggestedName)
    if candidate == "JSONValue" || context.knownTypeNames.contains(candidate) {
      return candidate + "Value"
    }
    return candidate
  }
}
