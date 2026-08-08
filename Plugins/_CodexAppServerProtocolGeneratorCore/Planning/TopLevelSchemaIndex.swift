import Foundation

struct TopLevelSchemaIndex {
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

      let fileURL = jsonRoot.appendingPathComponent(relativePath)
      let schema = try JSONObject(fileURL: fileURL)
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
