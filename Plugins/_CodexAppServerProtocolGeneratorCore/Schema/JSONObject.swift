import Foundation

struct JSONObject {
  let rawValue: Any

  init(fileURL: URL) throws {
    let data = try Data(contentsOf: fileURL)
    self.rawValue = try JSONSerialization.jsonObject(with: data, options: [])
  }

  func stringValue(forKey key: String) throws -> String? {
    guard let dictionary = rawValue as? [String: Any] else {
      throw GeneratorError.invalidSchema("expected top-level object")
    }
    return dictionary[key] as? String
  }

  func definitions() throws -> [String: Any] {
    guard let dictionary = rawValue as? [String: Any] else {
      throw GeneratorError.invalidSchema("expected top-level object")
    }
    return (dictionary["definitions"] as? [String: Any]) ?? [:]
  }
}
