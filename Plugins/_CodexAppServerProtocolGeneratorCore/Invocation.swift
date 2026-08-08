import Foundation

enum Command: String {
  case plan
  case validate
  case generate
}

enum OutputKind: String {
  case protocolModels = "protocol"
  case clientBindings = "client-bindings"
}

struct Invocation {
  let command: Command
  let outputKind: OutputKind
  let schemaRoot: URL
  let outputRoot: URL
  let isQuiet: Bool

  init(arguments: [String]) throws {
    var remaining = arguments
    let commandName = remaining.first.map { $0.hasPrefix("--") ? "plan" : $0 } ?? "plan"
    if remaining.first == commandName {
      remaining.removeFirst()
    }
    guard let command = Command(rawValue: commandName) else {
      throw GeneratorError.usage("unknown command '\(commandName)'")
    }

    var schemaRoot: URL?
    var outputRoot: URL?
    var outputKind = OutputKind.protocolModels
    var isQuiet = false
    var index = 0
    while index < remaining.count {
      let argument = remaining[index]
      switch argument {
      case "--quiet":
        isQuiet = true
      case "--schema-root":
        index += 1
        guard index < remaining.count else {
          throw GeneratorError.usage("--schema-root requires a path")
        }
        schemaRoot = URL(fileURLWithPath: remaining[index])
      case "--output-root":
        index += 1
        guard index < remaining.count else {
          throw GeneratorError.usage("--output-root requires a path")
        }
        outputRoot = URL(fileURLWithPath: remaining[index])
      case "--output-kind":
        index += 1
        guard index < remaining.count else {
          throw GeneratorError.usage("--output-kind requires protocol or client-bindings")
        }
        guard let parsed = OutputKind(rawValue: remaining[index]) else {
          throw GeneratorError.usage("--output-kind must be protocol or client-bindings")
        }
        outputKind = parsed
      case "--help", "-h":
        throw GeneratorError.usage(Self.help)
      default:
        throw GeneratorError.usage("unknown argument '\(argument)'")
      }
      index += 1
    }

    if command == .generate && outputRoot == nil {
      throw GeneratorError.usage("generate requires --output-root")
    }

    self.command = command
    self.outputKind = outputKind
    self.schemaRoot = schemaRoot ?? URL(fileURLWithPath: "Vendor/CodexAppServerProtocolSchema")
    self.outputRoot = outputRoot ?? URL(fileURLWithPath: ".build/codex-app-server-protocol-plan")
    self.isQuiet = isQuiet
  }

  static func isHelpRequest(_ arguments: [String]) -> Bool {
    arguments.count == 1 && ["--help", "-h"].contains(arguments[0])
  }

  static let help = """
    Usage:
      codex-app-server-protocol-generator plan [--schema-root DIR] [--output-root DIR] [--output-kind protocol|client-bindings]
      codex-app-server-protocol-generator validate [--schema-root DIR] [--output-root DIR] [--output-kind protocol|client-bindings]
      codex-app-server-protocol-generator generate [--schema-root DIR] --output-root DIR [--output-kind protocol|client-bindings] [--quiet]

    The generator reads only Vendor/CodexAppServerProtocolSchema and writes
    generated Swift only to the explicit output root used by the build plugin
    or an intentionally selected diagnostics directory.
    """
}
