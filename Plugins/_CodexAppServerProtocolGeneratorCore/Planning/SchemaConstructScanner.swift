struct SchemaConstructScanner {
  static func scan(_ value: Any, schemaPath: String) -> [ConstructUse] {
    var uses: [ConstructUse] = []
    scan(value, schemaPath: schemaPath, pointer: "", into: &uses)
    return uses
  }

  private static func scan(
    _ value: Any, schemaPath: String, pointer: String, into uses: inout [ConstructUse]
  ) {
    if let dictionary = value as? [String: Any] {
      for key in ["oneOf", "anyOf", "allOf", "const"] where dictionary[key] != nil {
        uses.append(ConstructUse(schemaPath: schemaPath, pointer: pointer, construct: .named(key)))
      }
      if let additionalProperties = dictionary["additionalProperties"] {
        if additionalProperties is [String: Any] {
          uses.append(
            ConstructUse(
              schemaPath: schemaPath, pointer: pointer, construct: .additionalPropertiesSchema))
        } else if let allowed = additionalProperties as? Bool, allowed {
          uses.append(
            ConstructUse(
              schemaPath: schemaPath, pointer: pointer, construct: .additionalPropertiesTrue))
        }
      }
      if let type = dictionary["type"] as? [String], type.count > 1 {
        if type.contains("null"), type.filter({ $0 != "null" }).count == 1 {
          uses.append(
            ConstructUse(schemaPath: schemaPath, pointer: pointer, construct: .nullableTypeUnion))
        } else {
          uses.append(
            ConstructUse(schemaPath: schemaPath, pointer: pointer, construct: .unsupportedTypeUnion)
          )
        }
      }
      for (key, child) in dictionary {
        scan(
          child, schemaPath: schemaPath, pointer: pointer + "/" + escapeJSONPointer(key),
          into: &uses)
      }
      return
    }
    if let array = value as? [Any] {
      for (index, child) in array.enumerated() {
        scan(child, schemaPath: schemaPath, pointer: pointer + "/\(index)", into: &uses)
      }
    }
  }

  private static func escapeJSONPointer(_ component: String) -> String {
    component.replacingOccurrences(of: "~", with: "~0")
      .replacingOccurrences(of: "/", with: "~1")
  }
}
