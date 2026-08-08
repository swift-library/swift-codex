import Foundation
import PackagePlugin

@main
struct CodexAppServerProtocolGenerator: BuildToolPlugin {
  func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
    guard target.name == "CodexAppServerProtocol" || target.name == "CodexAppServerClient" else {
      return []
    }

    let tool = try context.tool(named: "codex-app-server-protocol-generator")
    let packageDirectory = context.package.directoryURL
    let schemaRoot =
      packageDirectory
      .appendingPathComponent("Vendor")
      .appendingPathComponent("CodexAppServerProtocolSchema")
    let outputRoot = context.pluginWorkDirectoryURL
      .appendingPathComponent(target.name)
    let plan: PluginOutputPlan
    let outputKind: String
    let displayName: String
    if target.name == "CodexAppServerProtocol" {
      plan = try ProtocolOutputPlan(schemaRoot: schemaRoot, outputRoot: outputRoot)
      outputKind = "protocol"
      displayName = "Generate CodexAppServer protocol models"
    } else {
      plan = try ClientBindingOutputPlan(schemaRoot: schemaRoot, outputRoot: outputRoot)
      outputKind = "client-bindings"
      displayName = "Generate CodexAppServer client bindings"
    }

    return [
      .buildCommand(
        displayName: displayName,
        executable: tool.url,
        arguments: [
          "generate",
          "--schema-root",
          schemaRoot.path,
          "--output-root",
          outputRoot.path,
          "--output-kind",
          outputKind,
          "--quiet",
        ],
        inputFiles: plan.inputFiles,
        outputFiles: plan.outputFiles
      )
    ]
  }
}

private protocol PluginOutputPlan {
  var inputFiles: [URL] { get }
  var outputFiles: [URL] { get }
}

private struct ProtocolOutputPlan: PluginOutputPlan {
  let inputFiles: [URL]
  let outputFiles: [URL]

  init(schemaRoot: URL, outputRoot: URL) throws {
    let lockFile = schemaRoot.appendingPathComponent("upstream.lock.json")
    guard FileManager.default.fileExists(atPath: lockFile.path) else {
      throw PluginError.missingInput("missing upstream lock: \(lockFile.path)")
    }

    var inputFiles = [lockFile]
    var outputFiles = [
      outputRoot.appendingPathComponent("CodexAppServerProtocol.swift"),
      outputRoot
        .appendingPathComponent("Stable")
        .appendingPathComponent("CodexAppServerProtocol+Stable.swift"),
      outputRoot
        .appendingPathComponent("Experimental")
        .appendingPathComponent("CodexAppServerProtocol+Experimental.swift"),
    ]

    for surface in Surface.allCases {
      let jsonRoot =
        schemaRoot
        .appendingPathComponent(surface.rawValue)
        .appendingPathComponent("json")
      guard FileManager.default.fileExists(atPath: jsonRoot.path) else {
        throw PluginError.missingInput("missing schema tree: \(jsonRoot.path)")
      }

      inputFiles.append(contentsOf: try Self.schemaFiles(in: jsonRoot))
      outputFiles.append(
        contentsOf: try Self.generatedFiles(
          surface: surface,
          jsonRoot: jsonRoot,
          outputRoot: outputRoot
        ))
    }

    self.inputFiles = inputFiles.sorted { $0.path < $1.path }
    self.outputFiles = outputFiles.sorted { $0.path < $1.path }
  }

  private static func schemaFiles(in jsonRoot: URL) throws -> [URL] {
    try FileManager.default
      .subpathsOfDirectory(atPath: jsonRoot.path)
      .filter { $0.hasSuffix(".json") }
      .sorted()
      .map { jsonRoot.appendingPathComponent($0) }
  }

  private static func generatedFiles(
    surface: Surface,
    jsonRoot: URL,
    outputRoot: URL
  ) throws -> [URL] {
    let topLevelIndex = try TopLevelSchemaIndex(jsonRoot: jsonRoot)
    let classifier = try SchemaClassifier(surface: surface, jsonRoot: jsonRoot)
    var files: [URL] = []

    for schema in try aggregateSchemas(surface: surface, jsonRoot: jsonRoot) {
      let relativePath: String
      if let topLevelRelativePath = topLevelIndex.relativePath(for: schema.name) {
        relativePath = try classifier.outputRelativePath(
          for: topLevelRelativePath,
          typeName: schema.name
        )
      } else {
        relativePath = classifier.supportOutputRelativePath(
          for: schema.name,
          origin: schema.origin
        )
      }
      files.append(outputRoot.appendingPathComponent(relativePath))
    }

    return files
  }

  private static func aggregateSchemas(
    surface: Surface,
    jsonRoot: URL
  ) throws -> [AggregateSchema] {
    let rootAggregate = try JSONObject(
      fileURL: jsonRoot.appendingPathComponent("codex_app_server_protocol.schemas.json")
    )
    let v2Aggregate = try JSONObject(
      fileURL: jsonRoot.appendingPathComponent("codex_app_server_protocol.v2.schemas.json")
    )

    var schemas: [String: AggregateSchema] = [:]
    for name in try rootAggregate.definitionNames() where name != "v2" {
      schemas[name] = AggregateSchema(name: name, origin: .root)
    }
    for name in try v2Aggregate.definitionNames() {
      schemas[name] = AggregateSchema(name: name, origin: .v2)
    }

    return schemas.values.sorted { $0.name < $1.name }
  }
}

private struct ClientBindingOutputPlan: PluginOutputPlan {
  let inputFiles: [URL]
  let outputFiles: [URL]

  init(schemaRoot: URL, outputRoot: URL) throws {
    let lockFile = schemaRoot.appendingPathComponent("upstream.lock.json")
    guard FileManager.default.fileExists(atPath: lockFile.path) else {
      throw PluginError.missingInput("missing upstream lock: \(lockFile.path)")
    }

    let adoptionManifest = schemaRoot.appendingPathComponent("method-adoption.json")
    guard FileManager.default.fileExists(atPath: adoptionManifest.path) else {
      throw PluginError.missingInput(
        "missing method adoption manifest: \(adoptionManifest.path)"
      )
    }

    var inputFiles = [lockFile, adoptionManifest]
    for surface in Surface.allCases {
      let jsonRoot =
        schemaRoot
        .appendingPathComponent(surface.rawValue)
        .appendingPathComponent("json")
      guard FileManager.default.fileExists(atPath: jsonRoot.path) else {
        throw PluginError.missingInput("missing schema tree: \(jsonRoot.path)")
      }
      inputFiles.append(contentsOf: try Self.schemaFiles(in: jsonRoot))
    }

    self.inputFiles = inputFiles.sorted { $0.path < $1.path }
    self.outputFiles = [
      outputRoot.appendingPathComponent("CodexAppServerClient+StableBindings.swift"),
      outputRoot.appendingPathComponent("CodexAppServerClient+ExperimentalBindings.swift"),
      outputRoot.appendingPathComponent("CodexAppServerClient+MethodPolicy.swift"),
    ].sorted { $0.path < $1.path }
  }

  private static func schemaFiles(in jsonRoot: URL) throws -> [URL] {
    try FileManager.default
      .subpathsOfDirectory(atPath: jsonRoot.path)
      .filter { $0.hasSuffix(".json") }
      .sorted()
      .map { jsonRoot.appendingPathComponent($0) }
  }
}

private struct AggregateSchema {
  let name: String
  let origin: SchemaOrigin
}

private enum SchemaOrigin {
  case root
  case v2
}

private enum Surface: String, CaseIterable {
  case stable
  case experimental

  var namespaceName: String {
    switch self {
    case .stable:
      return "Stable"
    case .experimental:
      return "Experimental"
    }
  }
}

private struct TopLevelSchemaIndex {
  private let relativePathsByTypeName: [String: String]

  init(jsonRoot: URL) throws {
    let schemaFiles = try FileManager.default
      .subpathsOfDirectory(atPath: jsonRoot.path)
      .filter { $0.hasSuffix(".json") }
      .sorted()

    var relativePathsByTypeName: [String: String] = [:]
    for relativePath in schemaFiles {
      if relativePath.hasPrefix("codex_app_server_protocol.") {
        continue
      }

      let schema = try JSONObject(fileURL: jsonRoot.appendingPathComponent(relativePath))
      let typeName =
        try schema.stringValue(forKey: "title")
        ?? URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent
      relativePathsByTypeName[typeName] = relativePath
    }

    self.relativePathsByTypeName = relativePathsByTypeName
  }

  func relativePath(for typeName: String) -> String? {
    relativePathsByTypeName[typeName]
  }
}

private struct SchemaClassifier {
  let surface: Surface
  let serverRequestTypes: Set<String>
  let clientRequestTypes: Set<String>
  let notificationTypes: Set<String>

  init(surface: Surface, jsonRoot: URL) throws {
    self.surface = surface
    self.serverRequestTypes = try Self.referencedTypes(
      in: jsonRoot.appendingPathComponent("ServerRequest.json")
    )
    self.clientRequestTypes = try Self.referencedTypes(
      in: jsonRoot.appendingPathComponent("ClientRequest.json")
    )
    self.notificationTypes = try Self.referencedTypes(
      in: jsonRoot.appendingPathComponent("ServerNotification.json")
    )
  }

  func outputRelativePath(for schemaRelativePath: String, typeName: String) throws -> String {
    let root = surface.namespaceName
    let filename = "\(typeName)+\(surface.namespaceName).swift"

    if schemaRelativePath.hasPrefix("v1/") {
      return "\(root)/V1/\(filename)"
    }
    if schemaRelativePath.hasPrefix("v2/") {
      return "\(root)/V2/\(v2Bucket(typeName: typeName))/\(filename)"
    }
    if isJSONRPCEnvelope(typeName) {
      return "\(root)/JSONRPC/\(filename)"
    }
    if serverRequestTypes.contains(typeName)
      || serverRequestTypes.contains(pairTypeName(for: typeName))
    {
      return "\(root)/V2/ServerRequests/\(filename)"
    }
    if notificationTypes.contains(typeName) {
      return "\(root)/V2/Notifications/\(filename)"
    }
    if clientRequestTypes.contains(typeName)
      || clientRequestTypes.contains(pairTypeName(for: typeName))
    {
      return "\(root)/V2/\(v2Bucket(typeName: typeName))/\(filename)"
    }

    throw PluginError.unsupportedClassification(
      "cannot classify \(schemaRelativePath) with type \(typeName)"
    )
  }

  func supportOutputRelativePath(for typeName: String, origin: SchemaOrigin) -> String {
    let root = surface.namespaceName
    let filename = "\(typeName)+\(surface.namespaceName).swift"

    if isJSONRPCEnvelope(typeName) {
      return "\(root)/JSONRPC/\(filename)"
    }

    switch origin {
    case .root:
      return "\(root)/V1/Support/\(filename)"
    case .v2:
      return "\(root)/V2/Models/\(filename)"
    }
  }

  private func v2Bucket(typeName: String) -> String {
    if typeName.hasSuffix("Notification") {
      return "Notifications"
    }
    if typeName.hasSuffix("Response") {
      return "Responses"
    }
    return "Requests"
  }

  private func pairTypeName(for typeName: String) -> String {
    if typeName.hasSuffix("Response") {
      return String(typeName.dropLast("Response".count)) + "Params"
    }
    if typeName.hasSuffix("Params") {
      return String(typeName.dropLast("Params".count)) + "Response"
    }
    return typeName
  }

  private func isJSONRPCEnvelope(_ typeName: String) -> Bool {
    [
      "RequestId",
      "JSONRPCMessage",
      "JSONRPCRequest",
      "JSONRPCNotification",
      "JSONRPCResponse",
      "JSONRPCError",
      "JSONRPCErrorError",
      "ClientRequest",
      "ClientNotification",
      "ServerRequest",
      "ServerNotification",
    ].contains(typeName)
  }

  private static func referencedTypes(in fileURL: URL) throws -> Set<String> {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return []
    }
    let object = try JSONObject(fileURL: fileURL)
    var names = Set<String>()
    collectReferences(object.rawValue, into: &names)
    return names
  }

  private static func collectReferences(_ value: Any, into names: inout Set<String>) {
    if let dictionary = value as? [String: Any] {
      if let reference = dictionary["$ref"] as? String,
        reference.hasPrefix("#/definitions/")
      {
        names.insert(String(reference.dropFirst("#/definitions/".count)))
      }
      for child in dictionary.values {
        collectReferences(child, into: &names)
      }
      return
    }

    if let array = value as? [Any] {
      for child in array {
        collectReferences(child, into: &names)
      }
    }
  }
}

private struct JSONObject {
  let rawValue: Any

  init(fileURL: URL) throws {
    let data = try Data(contentsOf: fileURL)
    self.rawValue = try JSONSerialization.jsonObject(with: data, options: [])
  }

  func definitionNames() throws -> [String] {
    guard let dictionary = rawValue as? [String: Any],
      let definitions = dictionary["definitions"] as? [String: Any]
    else {
      throw PluginError.invalidSchema("schema is missing object definitions")
    }
    return definitions.keys.sorted()
  }

  func stringValue(forKey key: String) throws -> String? {
    guard let dictionary = rawValue as? [String: Any] else {
      throw PluginError.invalidSchema("schema root is not an object")
    }
    return dictionary[key] as? String
  }
}

private enum PluginError: Error, CustomStringConvertible {
  case missingInput(String)
  case invalidSchema(String)
  case unsupportedClassification(String)

  var description: String {
    switch self {
    case .missingInput(let message),
      .invalidSchema(let message),
      .unsupportedClassification(let message):
      return message
    }
  }
}
