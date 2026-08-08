import Foundation
import PackagePlugin

@main
struct CodexAppServerProtocolGeneratorCommand: CommandPlugin {
  func performCommand(context: PluginContext, arguments: [String]) async throws {
    let tool = try context.tool(named: "codex-app-server-protocol-generator")
    let process = Process()
    process.executableURL = tool.url
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()

    guard process.terminationReason == .exit && process.terminationStatus == 0 else {
      throw CommandPluginError.toolFailed(status: process.terminationStatus)
    }
  }
}

private enum CommandPluginError: Error, CustomStringConvertible {
  case toolFailed(status: Int32)

  var description: String {
    switch self {
    case .toolFailed(let status):
      return "codex-app-server-protocol-generator exited with status \(status)"
    }
  }
}
