import _CodexAppServerProtocolGeneratorCore

@main
struct CodexAppServerProtocolGeneratorTool {
  static func main() {
    CodexAppServerProtocolGeneratorToolDriver.run(
      arguments: Array(CommandLine.arguments.dropFirst())
    )
  }
}
