import Foundation

struct CodexOutputSchemaFile {
  let schemaPath: String?
  private let directoryURL: URL?

  init(outputSchema: CodexConfigObject?) throws {
    guard let outputSchema else {
      self.schemaPath = nil
      self.directoryURL = nil
      return
    }

    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-output-schema-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )

    let schemaURL = directoryURL.appendingPathComponent("schema.json")
    let jsonObject = try codexJSONObject(from: .object(outputSchema))
    let data = try JSONSerialization.data(withJSONObject: jsonObject)
    try data.write(to: schemaURL)

    self.schemaPath = schemaURL.path
    self.directoryURL = directoryURL
  }

  func cleanup() {
    guard let directoryURL else {
      return
    }

    try? FileManager.default.removeItem(at: directoryURL)
  }
}

func codexJSONObject(from value: CodexConfigValue) throws -> Any {
  switch value {
  case .null:
    return NSNull()
  case .bool(let value):
    return value
  case .number(let value):
    guard value.isFinite else {
      throw CodexProcessError(message: "JSON values must be finite")
    }
    return value
  case .string(let value):
    return value
  case .array(let values):
    return try values.map(codexJSONObject)
  case .object(let values):
    var object: [String: Any] = [:]
    for (key, child) in values {
      object[key] = try codexJSONObject(from: child)
    }
    return object
  }
}
