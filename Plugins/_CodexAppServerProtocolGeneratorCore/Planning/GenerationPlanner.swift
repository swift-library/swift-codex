import Foundation

struct GenerationPlanner {
  let schemaRoot: URL
  let outputRoot: URL

  func buildPlan() throws -> GenerationPlan {
    let lockFile = schemaRoot.appendingPathComponent("upstream.lock.json")
    guard FileManager.default.fileExists(atPath: lockFile.path) else {
      throw GeneratorError.missingInput("missing upstream lock: \(lockFile.path)")
    }

    var entries: [GenerationEntry] = []
    var constructUses: [ConstructUse] = []
    for surface in Surface.allCases {
      let jsonRoot = schemaRoot.appendingPathComponent(surface.rawValue).appendingPathComponent(
        "json")
      guard FileManager.default.fileExists(atPath: jsonRoot.path) else {
        throw GeneratorError.missingInput("missing schema tree: \(jsonRoot.path)")
      }
      let surfaceEntries = try loadEntries(surface: surface, jsonRoot: jsonRoot)
      entries.append(contentsOf: surfaceEntries.entries)
      constructUses.append(contentsOf: surfaceEntries.constructUses)
    }

    entries.sort { lhs, rhs in
      lhs.outputRelativePath == rhs.outputRelativePath
        ? lhs.schemaRelativePath < rhs.schemaRelativePath
        : lhs.outputRelativePath < rhs.outputRelativePath
    }

    return GenerationPlan(outputRoot: outputRoot, entries: entries, constructUses: constructUses)
  }

  private func loadEntries(
    surface: Surface,
    jsonRoot: URL
  ) throws -> (entries: [GenerationEntry], constructUses: [ConstructUse]) {
    let topLevelIndex = try TopLevelSchemaIndex(jsonRoot: jsonRoot)
    let classifier = try SchemaClassifier(surface: surface, jsonRoot: jsonRoot)
    let rootAggregate = try JSONObject(
      fileURL: jsonRoot.appendingPathComponent("codex_app_server_protocol.schemas.json")
    )
    let v2Aggregate = try JSONObject(
      fileURL: jsonRoot.appendingPathComponent("codex_app_server_protocol.v2.schemas.json")
    )

    var schemas: [String: CanonicalSchema] = [:]

    for (name, schema) in try rootAggregate.definitions() where name != "v2" {
      schemas[name] = CanonicalSchema(
        schema: schema,
        schemaRelativePath:
          "\(surface.rawValue)/json/codex_app_server_protocol.schemas.json#/definitions/\(name)",
        origin: .root
      )
    }

    for (name, schema) in try v2Aggregate.definitions() {
      schemas[name] = CanonicalSchema(
        schema: schema,
        schemaRelativePath:
          "\(surface.rawValue)/json/codex_app_server_protocol.v2.schemas.json#/definitions/\(name)",
        origin: .v2
      )
    }

    let knownTypeNames = Set(schemas.keys.map(SwiftNames.type))
    var entries: [GenerationEntry] = []
    var constructUses: [ConstructUse] = []

    for typeName in schemas.keys.sorted() {
      guard let canonical = schemas[typeName] else {
        continue
      }
      let outputRelativePath: String
      if let topLevelRelativePath = topLevelIndex.relativePath(for: typeName) {
        outputRelativePath = try classifier.outputRelativePath(
          for: topLevelRelativePath, typeName: typeName)
      } else {
        outputRelativePath = classifier.supportOutputRelativePath(
          for: typeName, origin: canonical.origin)
      }
      let constructs = SchemaConstructScanner.scan(
        canonical.schema, schemaPath: canonical.schemaRelativePath)

      constructUses.append(contentsOf: constructs)
      entries.append(
        GenerationEntry(
          surface: surface,
          schemaRelativePath: canonical.schemaRelativePath,
          typeName: typeName,
          outputRelativePath: outputRelativePath,
          schema: canonical.schema,
          knownTypeNames: knownTypeNames,
          constructUses: constructs
        ))
    }

    return (entries, constructUses)
  }
}

struct CanonicalSchema {
  let schema: Any
  let schemaRelativePath: String
  let origin: SchemaOrigin
}

enum SchemaOrigin {
  case root
  case v2
}
