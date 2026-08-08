struct ConstructUse {
  let schemaPath: String
  let pointer: String
  let construct: SchemaConstruct
}

enum SchemaConstruct: String, Hashable {
  case oneOf
  case anyOf
  case allOf
  case const
  case nullableTypeUnion = "type:nullable-union"
  case unsupportedTypeUnion = "type:unsupported-union"
  case additionalPropertiesSchema = "additionalProperties:schema"
  case additionalPropertiesTrue = "additionalProperties:true"

  static func named(_ key: String) -> SchemaConstruct {
    switch key {
    case "oneOf":
      return .oneOf
    case "anyOf":
      return .anyOf
    case "allOf":
      return .allOf
    case "const":
      return .const
    default:
      return .unsupportedTypeUnion
    }
  }
}

struct SchemaConstructMapping {
  let swiftStrategy: String

  static func policy(for construct: SchemaConstruct) -> SchemaConstructMapping? {
    switch construct {
    case .oneOf:
      return SchemaConstructMapping(
        swiftStrategy:
          "Generate an enum for tagged or untagged upstream unions, preserving branch order and raw discriminator values."
      )
    case .anyOf:
      return SchemaConstructMapping(
        swiftStrategy:
          "Generate optional wrappers when one branch is null; otherwise generate a union enum with branch-specific decoding."
      )
    case .allOf:
      return SchemaConstructMapping(
        swiftStrategy:
          "Generate a flattened composite model by merging referenced/object constraints before emission."
      )
    case .const:
      return SchemaConstructMapping(
        swiftStrategy:
          "Generate discriminator constants used for encode/decode validation rather than mutable stored properties."
      )
    case .nullableTypeUnion:
      return SchemaConstructMapping(
        swiftStrategy: "Generate Optional<T> for the single non-null JSON Schema type."
      )
    case .additionalPropertiesSchema:
      return SchemaConstructMapping(
        swiftStrategy:
          "Generate Dictionary<String, Value> where Value is the mapped schema for additional properties."
      )
    case .additionalPropertiesTrue:
      return SchemaConstructMapping(
        swiftStrategy:
          "Generate a dynamic JSON dictionary using the target-local JSON value representation."
      )
    case .unsupportedTypeUnion:
      return nil
    }
  }
}
