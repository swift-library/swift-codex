import Foundation
import Testing
import _CodexProcess

@Suite("Codex native executable discovery")
struct CodexExecutableDiscoveryTests {
  @Test("Missing and empty PATH never consult the host environment")
  func explicitEnvironment() throws {
    #expect(try CodexExecutableDiscovery.find(named: "codex", environment: [:]) == nil)
    #expect(try CodexExecutableDiscovery.find(named: "codex", environment: ["PATH": ""]) == nil)
  }

  @Test("Discovery rejects paths and embedded NUL", arguments: ["", "dir/codex", "codex\u{0}"])
  func bareCommand(name: String) {
    #expect(!CodexExecutableDiscovery.isBareName(name))
  }

  #if !os(Windows)
    @Test("POSIX PATH preserves search order, skips directories and requires executable files")
    func pathOrder() throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let directories = ["directory", "non executable", "first", "second"].map {
        root.appendingPathComponent($0)
      }
      for directory in directories {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      }
      try FileManager.default.createDirectory(
        at: directories[0].appendingPathComponent("codex"), withIntermediateDirectories: false)
      for (index, directory) in directories.enumerated() where index > 0 {
        let file = directory.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
        try FileManager.default.setAttributes(
          [.posixPermissions: index == 1 ? 0o644 : 0o755], ofItemAtPath: file.path)
      }
      let path = directories.map(\.path).joined(separator: ":")
      let found = try CodexExecutableDiscovery.find(
        named: "codex", environment: ["PATH": ":\(path)::"])
      let result = try #require(found)
      #expect(result.executable == directories[2].appendingPathComponent("codex"))
      #expect(result.directory == directories[2].path)
    }

    @Test("POSIX environment overrides preserve distinct case-sensitive names")
    func environmentNames() throws {
      let environment = ["Path": "other", "PATH": "exact", "codex_api_key": "case-sensitive"]
      #expect(try CodexProcessEnvironment.value(for: "PATH", in: environment) == "exact")
      let result = try CodexProcessEnvironment.setting(
        "configured", for: "CODEX_API_KEY", in: environment)
      #expect(result["codex_api_key"] == "case-sensitive")
      #expect(result["CODEX_API_KEY"] == "configured")
    }
  #endif
}
