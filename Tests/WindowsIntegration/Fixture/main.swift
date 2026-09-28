import Foundation

#if os(Windows)
  import WinSDK

  @main
  struct CodexProcessFixture {
    static func main() async throws {
      let environment = ProcessInfo.processInfo.environment
      let requested = CommandLine.arguments.dropFirst().first ?? ""
      let mode =
        ["branch", "leaf"].contains(requested)
        ? requested : environment["CODEX_FIXTURE_MODE"] ?? "echo"
      let directory = environment["CODEX_FIXTURE_DIRECTORY"] ?? ""
      switch mode {
      case "echo":
        let input = try FileHandle.standardInput.readToEnd() ?? Data()
        let value: [String: Any] = [
          "arguments": Array(CommandLine.arguments.dropFirst()),
          "cwd": FileManager.default.currentDirectoryPath,
          "value": environment["VALUE"] ?? "",
          "hostOnly": environment["SWIFT_CODEX_HOST_ONLY"] ?? "",
          "input": String(decoding: input, as: UTF8.self),
          "configuredKeyMatches": environment["CODEX_API_KEY"] == "fixture-configured-key",
        ]
        try FileHandle.standardOutput.write(
          contentsOf: JSONSerialization.data(withJSONObject: value) + Data([10]))
      case "lines":
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
          var count: DWORD = 0
          guard ReadFile(GetStdHandle(STD_INPUT_HANDLE), &bytes, DWORD(bytes.count), &count, nil)
          else {
            if GetLastError() == ERROR_BROKEN_PIPE { return }
            ExitProcess(6)
          }
          if count == 0 { return }
          try FileHandle.standardOutput.write(contentsOf: Data(bytes.prefix(Int(count))))
        }
      case "blocked-input":
        try record("root", in: directory)
        try output("ready\n")
        var bytes = [UInt8](repeating: 0, count: 1024)
        var count: DWORD = 0
        guard ReadFile(GetStdHandle(STD_INPUT_HANDLE), &bytes, DWORD(bytes.count), &count, nil),
          count > 0
        else { ExitProcess(4) }
        try output("receiving\n")
        try await Task.sleep(for: .seconds(60))
      case "tree", "tree-exit", "branch", "leaf":
        if mode != "leaf" {
          let child = Process()
          child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
          child.arguments = [mode == "branch" ? "leaf" : "branch"]
          child.environment = environment
          child.standardOutput = FileHandle.standardOutput
          child.standardError = FileHandle.standardError
          try child.run()
          try await waitFor(mode == "branch" ? "leaf" : "branch", in: directory)
          try record(mode == "branch" ? "branch" : "root", in: directory)
          if mode != "branch" { try output("ready\n") }
          if mode == "tree-exit" {
            try await waitFor("release", in: directory)
            ExitProcess(0)
          }
          try await Task.sleep(for: .seconds(60))
        } else {
          try record("leaf", in: directory)
          try await Task.sleep(for: .seconds(60))
        }
      case "output":
        try output("kept\n")
        try FileHandle.standardOutput.write(contentsOf: Data(repeating: 120, count: 2_000_000))
        try output("\nlast\n")
        try FileHandle.standardError.write(contentsOf: Data(repeating: 121, count: 2_000_000))
      case "exit":
        ExitProcess(DWORD(environment["CODEX_FIXTURE_EXIT"] ?? "0")!)
      default: ExitProcess(3)
      }
    }

    private static func output(_ text: String) throws {
      try FileHandle.standardOutput.write(contentsOf: Data(text.utf8))
    }

    private static func record(_ name: String, in directory: String) throws {
      try Data(String(GetCurrentProcessId()).utf8).write(
        to: URL(fileURLWithPath: directory).appendingPathComponent(name), options: .atomic)
    }

    private static func waitFor(_ name: String, in directory: String) async throws {
      let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
      let deadline = ContinuousClock.now.advanced(by: .seconds(15))
      while !FileManager.default.fileExists(atPath: path) {
        guard ContinuousClock.now < deadline else { ExitProcess(5) }
        try await Task.sleep(for: .milliseconds(10))
      }
    }
  }
#else
  @main
  struct CodexProcessFixture {
    static func main() { fatalError("This fixture requires Windows.") }
  }
#endif
