import Foundation

struct ClientBindingPlan {
  let outputRoot: URL
  let bindings: [ClientBinding]
  let adoption: ClientMethodAdoption

  var outputRelativePaths: [String] {
    Surface.allCases.map { "CodexAppServerClient+\($0.namespaceName)Bindings.swift" }
      + ["CodexAppServerClient+MethodPolicy.swift"]
  }

  func textSummary() -> String {
    var lines: [String] = []
    lines.append("CodexAppServer client binding generation plan")
    lines.append("outputRoot: \(outputRoot.path)")
    lines.append("bindings: \(bindings.count)")
    for surface in Surface.allCases {
      lines.append("\(surface.rawValue): \(bindings.filter { $0.surface == surface }.count)")
    }
    lines.append("sampleBindings:")
    for binding in bindings.prefix(16) {
      lines.append("- \(binding.surface.rawValue) \(binding.method) -> \(binding.functionName)")
    }
    lines.append("excludedMethods:")
    for exclusion in adoption.exclusions {
      lines.append("- \(exclusion.method): \(exclusion.reason)")
    }
    return lines.joined(separator: "\n")
  }

  func validateForGeneration() throws {
    let duplicateSignatures = Dictionary(grouping: bindings) {
      "\($0.functionName)(\($0.paramsTypeName ?? ""))"
    }
    .filter { $0.value.count > 1 }

    guard duplicateSignatures.isEmpty else {
      let examples = duplicateSignatures.keys.sorted().prefix(20).map { "  - \($0)" }
        .joined(separator: "\n")
      throw GeneratorError.invalidSchema(
        """
        generated client binding signatures are not unique
        \(examples)
        """)
    }
  }
}

struct ClientBinding: Equatable, Sendable {
  let surface: Surface
  let method: String
  let functionName: String
  let paramsTypeName: String?
  let paramsIsOptional: Bool
  let paramsDefaultExpression: String?
  let responseTypeName: String
}

struct ClientBindingPlanner {
  let schemaRoot: URL
  let outputRoot: URL

  func buildPlan() throws -> ClientBindingPlan {
    let lockFile = schemaRoot.appendingPathComponent("upstream.lock.json")
    guard FileManager.default.fileExists(atPath: lockFile.path) else {
      throw GeneratorError.missingInput("missing upstream lock: \(lockFile.path)")
    }

    let adoption = try ClientMethodAdoption.load(schemaRoot: schemaRoot)
    let stableSchemaMethods = try schemaMethods(surface: .stable)
    let experimentalSchemaMethods = try schemaMethods(surface: .experimental)
    try adoption.validate(
      stableSchemaMethods: stableSchemaMethods,
      experimentalSchemaMethods: experimentalSchemaMethods
    )

    let stableMethods = try Set(loadBindings(surface: .stable, adoption: adoption).map(\.method))
    var allBindings: [ClientBinding] = []
    for surface in Surface.allCases {
      let surfaceBindings = try loadBindings(surface: surface, adoption: adoption)
      if surface == .experimental {
        allBindings.append(
          contentsOf: surfaceBindings.filter { !stableMethods.contains($0.method) })
      } else {
        allBindings.append(contentsOf: surfaceBindings)
      }
    }

    allBindings.sort {
      $0.surface == $1.surface
        ? $0.method < $1.method
        : $0.surface.rawValue < $1.surface.rawValue
    }

    return ClientBindingPlan(outputRoot: outputRoot, bindings: allBindings, adoption: adoption)
  }

  private func schemaMethods(surface: Surface) throws -> Set<String> {
    let jsonRoot = schemaRoot.appendingPathComponent(surface.rawValue).appendingPathComponent(
      "json")
    let requestObject = try JSONObject(
      fileURL: jsonRoot.appendingPathComponent("ClientRequest.json"))
    let requestSchema = try SchemaNode.object(requestObject.rawValue)
    guard let branches = requestSchema["oneOf"] as? [Any] else {
      throw GeneratorError.invalidSchema(
        "ClientRequest.json does not contain oneOf request branches")
    }
    return try Set(
      branches.map { branch in
        let schema = try SchemaNode.object(branch)
        let properties = try SchemaNode.object(schema["properties"] as Any)
        let methodSchema = try SchemaNode.object(properties["method"] as Any)
        guard let method = (methodSchema["enum"] as? [String])?.first else {
          throw GeneratorError.invalidSchema("client request is missing method enum")
        }
        return method
      })
  }

  private func loadBindings(
    surface: Surface,
    adoption: ClientMethodAdoption
  ) throws -> [ClientBinding] {
    let jsonRoot = schemaRoot.appendingPathComponent(surface.rawValue).appendingPathComponent(
      "json")
    guard FileManager.default.fileExists(atPath: jsonRoot.path) else {
      throw GeneratorError.missingInput("missing schema tree: \(jsonRoot.path)")
    }

    let knownTypeNames = try knownTypes(jsonRoot: jsonRoot)
    let requestObject = try JSONObject(
      fileURL: jsonRoot.appendingPathComponent("ClientRequest.json"))
    let requestDefinitions = try requestObject.definitions()
    let requestSchema = try SchemaNode.object(requestObject.rawValue)
    guard let branches = requestSchema["oneOf"] as? [Any] else {
      throw GeneratorError.invalidSchema(
        "ClientRequest.json does not contain oneOf request branches")
    }

    var usedFunctionNames = Set<String>()
    return try branches.compactMap { branch in
      let schema = try SchemaNode.object(branch)
      let title = try requiredString(schema["title"], context: "client request title")
      let properties = try SchemaNode.object(schema["properties"] as Any)
      let methodSchema = try SchemaNode.object(properties["method"] as Any)
      guard let method = (methodSchema["enum"] as? [String])?.first else {
        throw GeneratorError.invalidSchema("\(title) is missing method enum")
      }
      guard adoption.includesTypedRequest(method) else {
        return nil
      }

      let params = try paramsBinding(
        properties: properties,
        definitions: requestDefinitions
      )
      let responseTypeName = try responseTypeName(
        method: method,
        paramsTypeName: params.typeName,
        knownTypeNames: knownTypeNames
      )

      return ClientBinding(
        surface: surface,
        method: method,
        functionName: SwiftNames.method(method, used: &usedFunctionNames),
        paramsTypeName: params.typeName,
        paramsIsOptional: params.isOptional,
        paramsDefaultExpression: params.defaultExpression,
        responseTypeName: responseTypeName
      )
    }
  }

  private func knownTypes(jsonRoot: URL) throws -> Set<String> {
    var names = Set<String>()
    let rootAggregate = try JSONObject(
      fileURL: jsonRoot.appendingPathComponent("codex_app_server_protocol.schemas.json")
    )
    let v2Aggregate = try JSONObject(
      fileURL: jsonRoot.appendingPathComponent("codex_app_server_protocol.v2.schemas.json")
    )
    names.formUnion(try rootAggregate.definitions().keys.map(SwiftNames.type))
    names.formUnion(try v2Aggregate.definitions().keys.map(SwiftNames.type))
    return names
  }

  private func paramsBinding(
    properties: [String: Any],
    definitions: [String: Any]
  ) throws -> (typeName: String?, isOptional: Bool, defaultExpression: String?) {
    guard let params = properties["params"] else {
      return (nil, false, nil)
    }
    let paramsSchema = try SchemaNode.object(params)
    if paramsSchema["type"] as? String == "null" {
      return (nil, false, nil)
    }

    let reference: String
    let isOptional: Bool
    if let directReference = paramsSchema["$ref"] as? String {
      reference = directReference
      isOptional = false
    } else {
      let alternatives = paramsSchema["anyOf"] as? [Any] ?? []
      let references = alternatives.compactMap { value -> String? in
        guard let object = try? SchemaNode.object(value) else { return nil }
        return object["$ref"] as? String
      }
      let containsNull = alternatives.contains { value in
        guard let object = try? SchemaNode.object(value) else { return false }
        return object["type"] as? String == "null"
      }
      guard alternatives.count == 2, references.count == 1, containsNull else {
        throw GeneratorError.invalidSchema("client request params must be a schema reference")
      }
      reference = references[0]
      isOptional = true
    }
    let referenceName = SwiftNames.referenceName(reference)
    return (
      SwiftNames.type(referenceName),
      isOptional,
      isOptional ? "nil" : (isEmptyObjectDefinition(definitions[referenceName]) ? "[:]" : nil)
    )
  }

  private func isEmptyObjectDefinition(_ value: Any?) -> Bool {
    guard let value,
      let definition = try? SchemaNode.object(value),
      definition["type"] as? String == "object"
    else {
      return false
    }

    let properties = definition["properties"] as? [String: Any]
    let required = definition["required"] as? [String]
    return (properties?.isEmpty ?? true) && (required?.isEmpty ?? true)
  }

  private func responseTypeName(
    method: String,
    paramsTypeName: String?,
    knownTypeNames: Set<String>
  ) throws -> String {
    if let override = Self.responseTypeOverrides[method] {
      return override
    }

    if let paramsTypeName,
      paramsTypeName.hasSuffix("Params")
    {
      let candidate = String(paramsTypeName.dropLast("Params".count)) + "Response"
      if knownTypeNames.contains(candidate) {
        return candidate
      }
    }

    let methodCandidate = SwiftNames.type(method) + "Response"
    if knownTypeNames.contains(methodCandidate) {
      return methodCandidate
    }

    throw GeneratorError.invalidSchema("missing response type for client request method \(method)")
  }

  private func requiredString(_ value: Any?, context: String) throws -> String {
    guard let value = value as? String else {
      throw GeneratorError.invalidSchema("missing \(context)")
    }
    return value
  }

  private static let responseTypeOverrides: [String: String] = [
    "account/logout": "LogoutAccountResponse",
    "account/rateLimits/read": "GetAccountRateLimitsResponse",
    "account/usage/read": "GetAccountTokenUsageResponse",
    "account/workspaceMessages/read": "GetWorkspaceMessagesResponse",
    "config/batchWrite": "ConfigWriteResponse",
    "config/mcpServer/reload": "McpServerRefreshResponse",
    "config/value/write": "ConfigWriteResponse",
    "configRequirements/read": "ConfigRequirementsReadResponse",
    "externalAgentConfig/import/readHistories": "ExternalAgentConfigImportHistoriesReadResponse",
  ]
}
