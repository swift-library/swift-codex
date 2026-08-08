import Foundation

extension CodexExecClient {
  func makePreparedLaunch(for kind: CodexExecLaunchKind) throws -> CodexExecPreparedLaunch {
    let executableURL = try executableResolver.resolveExecutable(using: configuration)
    var environment = configuration.environmentOverride ?? ProcessInfo.processInfo.environment

    if let apiKey = configuration.apiKey {
      environment["CODEX_API_KEY"] = apiKey
    }

    let workingDirectory = effectiveWorkingDirectory(for: kind)
    let promptMapping = promptMapping(for: kind)

    return CodexExecPreparedLaunch(
      kind: kind,
      executableURL: executableURL,
      arguments: arguments(
        for: kind, workingDirectory: workingDirectory, promptMapping: promptMapping),
      environment: environment,
      workingDirectory: workingDirectory,
      standardInput: promptMapping.standardInput
    )
  }

  func arguments(
    for kind: CodexExecLaunchKind,
    workingDirectory: URL?,
    promptMapping: CodexExecPromptMapping
  ) -> [String] {
    var arguments = ["exec"]
    arguments.append(contentsOf: sharedArguments(for: kind, workingDirectory: workingDirectory))

    switch kind {
    case .run(let request):
      arguments.append(contentsOf: repeatedFlag("--image", values: request.options.images))
      if let promptArgument = promptMapping.promptArgument {
        arguments.append(promptArgument)
      }
    case .resume(let request):
      arguments.append("resume")
      switch request.selector {
      case .sessionID(let sessionID):
        arguments.append(sessionID)
      case .last:
        arguments.append("--last")
      case .lastAll:
        arguments.append("--last")
        arguments.append("--all")
      }

      arguments.append(contentsOf: repeatedFlag("--image", values: request.options.images))
      if let promptArgument = promptMapping.promptArgument {
        arguments.append(promptArgument)
      }
    }

    return arguments
  }

  func sharedArguments(for kind: CodexExecLaunchKind, workingDirectory: URL?) -> [String] {
    let outputMode: CodexExecOutputMode
    let outputSchemaFile: URL?
    let outputLastMessageFile: URL?
    let options: CodexExecRequestOptions

    switch kind {
    case .run(let request):
      outputMode = request.outputMode
      outputSchemaFile = request.outputSchemaFile
      outputLastMessageFile = request.outputLastMessageFile
      options = request.options
    case .resume(let request):
      outputMode = request.outputMode
      outputSchemaFile = request.outputSchemaFile
      outputLastMessageFile = request.outputLastMessageFile
      options = request.options
    }

    var arguments: [String] = []

    if outputMode == .jsonl {
      arguments.append("--json")
    }

    if let outputSchemaFile {
      arguments.append(contentsOf: ["--output-schema", outputSchemaFile.path])
    }

    if let outputLastMessageFile {
      arguments.append(contentsOf: ["--output-last-message", outputLastMessageFile.path])
    }

    arguments.append(
      contentsOf: repeatedFlag("--add-dir", values: options.additionalWritableDirectories))

    if let approvalMode = options.approvalMode {
      arguments.append(contentsOf: ["--ask-for-approval", approvalMode])
    }

    if options.searchEnabled == true {
      arguments.append("--search")
    }

    arguments.append(contentsOf: repeatedFlag("--enable", values: options.enabledFeatures))
    arguments.append(contentsOf: repeatedFlag("--disable", values: options.disabledFeatures))

    if let model = options.model {
      arguments.append(contentsOf: ["--model", model])
    }

    if options.useOSS {
      arguments.append("--oss")
    }

    if let profile = options.profile {
      arguments.append(contentsOf: ["--profile", profile])
    }

    if let sandboxMode = options.sandboxMode {
      arguments.append(contentsOf: ["--sandbox", sandboxMode])
    }

    if options.fullAuto {
      arguments.append("--full-auto")
    }

    if options.dangerouslyBypassApprovalsAndSandbox {
      arguments.append("--dangerously-bypass-approvals-and-sandbox")
    }

    if options.ephemeral {
      arguments.append("--ephemeral")
    }

    if let colorMode = options.colorMode {
      arguments.append(contentsOf: ["--color", colorMode])
    }

    if options.skipGitRepoCheck {
      arguments.append("--skip-git-repo-check")
    }

    arguments.append(contentsOf: repeatedFlag("--config", values: options.configOverrides))

    if let workingDirectory {
      arguments.append(contentsOf: ["--cd", workingDirectory.path])
    }

    return arguments
  }

  func effectiveWorkingDirectory(for kind: CodexExecLaunchKind) -> URL? {
    switch kind {
    case .run(let request):
      return request.options.workingDirectory ?? configuration.defaultWorkingDirectory
    case .resume(let request):
      return request.options.workingDirectory ?? configuration.defaultWorkingDirectory
    }
  }

  func promptMapping(for kind: CodexExecLaunchKind) -> CodexExecPromptMapping {
    let promptInput: CodexExecPromptInput?

    switch kind {
    case .run(let request):
      promptInput = request.promptInput
    case .resume(let request):
      promptInput = request.promptInput
    }

    guard let promptInput else {
      return CodexExecPromptMapping(promptArgument: nil, standardInput: nil)
    }

    switch promptInput {
    case .text(let prompt):
      return CodexExecPromptMapping(
        promptArgument: prompt,
        standardInput: nil
      )
    case .stdin(let stdin):
      return CodexExecPromptMapping(
        promptArgument: "-",
        standardInput: Data(stdin.utf8)
      )
    case .textWithStdinContext(let prompt, let stdin):
      return CodexExecPromptMapping(
        promptArgument: prompt,
        standardInput: Data(stdin.utf8)
      )
    }
  }

  func requestSemantics(for kind: CodexExecLaunchKind) -> CodexExecRequestSemantics {
    switch kind {
    case .run(let request):
      return CodexExecRequestSemantics(
        promptInput: request.promptInput,
        outputSchemaFile: request.outputSchemaFile,
        outputLastMessageFile: request.outputLastMessageFile
      )
    case .resume(let request):
      return CodexExecRequestSemantics(
        promptInput: request.promptInput,
        outputSchemaFile: request.outputSchemaFile,
        outputLastMessageFile: request.outputLastMessageFile
      )
    }
  }

  func validatePreLaunchRequestSemantics(_ requestSemantics: CodexExecRequestSemantics) throws {
    if case .stdin(let stdin)? = requestSemantics.promptInput, stdin.isEmpty {
      throw CodexExecError.invalidInvocation(description: "Prompt stdin cannot be empty.")
    }

    if let outputSchemaFile = requestSemantics.outputSchemaFile {
      try validateOutputSchemaFile(at: outputSchemaFile)
    }
  }

  func validateOutputSchemaFile(at path: URL) throws {
    let schemaData: Data
    do {
      schemaData = try Data(contentsOf: path)
    } catch {
      throw CodexExecError.invalidInvocation(
        description: "Failed to read output schema file \(path.path): \(error.localizedDescription)"
      )
    }

    do {
      _ = try JSONSerialization.jsonObject(with: schemaData)
    } catch {
      throw CodexExecError.invalidInvocation(
        description:
          "Output schema file \(path.path) is not valid JSON: \(error.localizedDescription)"
      )
    }
  }

  func repeatedFlag(_ flag: String, values: [URL]) -> [String] {
    values.flatMap { [flag, $0.path] }
  }

  func repeatedFlag(_ flag: String, values: [String]) -> [String] {
    values.flatMap { [flag, $0] }
  }
}

struct CodexExecPromptMapping: Equatable, Sendable {
  var promptArgument: String?
  var standardInput: Data?
}

struct CodexExecRequestSemantics {
  var promptInput: CodexExecPromptInput?
  var outputSchemaFile: URL?
  var outputLastMessageFile: URL?
}
