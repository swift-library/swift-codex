import Foundation

struct SchemaClassifier {
  let surface: Surface
  let jsonRoot: URL
  let serverRequestTypes: Set<String>
  let clientRequestTypes: Set<String>
  let notificationTypes: Set<String>

  init(surface: Surface, jsonRoot: URL) throws {
    self.surface = surface
    self.jsonRoot = jsonRoot
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
    let root = surface == .stable ? "Stable" : "Experimental"
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

    throw GeneratorError.unsupportedClassification(
      "cannot classify \(schemaRelativePath) with type \(typeName)"
    )
  }

  func supportOutputRelativePath(for typeName: String, origin: SchemaOrigin) -> String {
    let root = surface == .stable ? "Stable" : "Experimental"
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
