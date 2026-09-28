import Foundation

package enum CodexExecutableDiscovery {
  package static func isBareName(_ name: String) -> Bool {
    guard !name.isEmpty, !name.utf8.contains(0), !name.contains("/") else { return false }
    #if os(Windows)
      return !name.contains("\\") && !name.contains(":")
    #else
      return true
    #endif
  }

  package static func find(
    named name: String, environment: [String: String]
  ) throws -> (executable: URL, directory: String)? {
    guard isBareName(name) else {
      throw CodexProcessFailure(description: "Executable name must be a bare command name.")
    }
    let path = try CodexProcessEnvironment.value(for: "PATH", in: environment) ?? ""
    #if os(Windows)
      let separator: Character = ";"
      // CreateProcess launches native images directly; PATH discovery never selects
      // a command script or consults PATHEXT to introduce a shell intermediary.
      let executableName = name.lowercased().hasSuffix(".exe") ? name : name + ".exe"
    #else
      let separator: Character = ":"
      let executableName = name
    #endif
    for entry in path.split(separator: separator) {
      var directory = String(entry)
      #if os(Windows)
        if directory.hasPrefix("\""), directory.hasSuffix("\""), directory.count >= 2 {
          directory.removeFirst()
          directory.removeLast()
        }
      #endif
      // Empty PATH components never introduce an implicit current-directory search.
      guard !directory.isEmpty, !directory.utf8.contains(0) else { continue }
      let candidate = URL(fileURLWithPath: directory, isDirectory: true)
        .appendingPathComponent(executableName)
      var isDirectory = ObjCBool(false)
      if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
        !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: candidate.path)
      {
        return (candidate, directory)
      }
    }
    return nil
  }
}
