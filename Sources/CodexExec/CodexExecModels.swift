import Foundation

/// Process launch defaults for upstream exec requests.
public struct CodexExecLaunchConfiguration: Equatable, Sendable {
  /// Optional absolute path to the `codex` executable.
  public var executableURL: URL?
  /// Optional replacement environment for the launched process.
  public var environmentOverride: [String: String]?
  /// Optional API key injected as `CODEX_API_KEY`.
  public var apiKey: String?
  /// Default working directory used when a request does not specify one.
  public var defaultWorkingDirectory: URL?

  /// Creates process launch defaults.
  public init(
    executableURL: URL? = nil,
    environmentOverride: [String: String]? = nil,
    apiKey: String? = nil,
    defaultWorkingDirectory: URL? = nil
  ) {
    self.executableURL = executableURL
    self.environmentOverride = environmentOverride
    self.apiKey = apiKey
    self.defaultWorkingDirectory = defaultWorkingDirectory
  }
}

/// Upstream-documented options shared by `codex exec` and `codex exec resume`.
public struct CodexExecRequestOptions: Equatable, Sendable {
  /// Image paths supplied through repeated upstream image flags.
  public var images: [URL]
  /// Additional writable directories supplied through repeated add-dir flags.
  public var additionalWritableDirectories: [URL]
  /// Upstream approval mode value.
  public var approvalMode: String?
  /// Enables upstream web search when true.
  public var searchEnabled: Bool?
  /// Feature flags enabled for the request.
  public var enabledFeatures: [String]
  /// Feature flags disabled for the request.
  public var disabledFeatures: [String]
  /// Optional upstream model identifier.
  public var model: String?
  /// Whether to request upstream OSS model behavior.
  public var useOSS: Bool
  /// Request working directory.
  public var workingDirectory: URL?
  /// Optional upstream color mode.
  public var colorMode: String?
  /// Whether to pass the upstream dangerous approvals/sandbox bypass flag.
  public var dangerouslyBypassApprovalsAndSandbox: Bool
  /// Whether to pass the upstream ephemeral flag.
  public var ephemeral: Bool
  /// Whether to ignore the user's Codex config while retaining `CODEX_HOME` authentication.
  public var ignoreUserConfig: Bool
  /// Whether to pass the upstream full-auto flag.
  public var fullAuto: Bool
  /// Optional upstream profile name.
  public var profile: String?
  /// Optional upstream sandbox mode value.
  public var sandboxMode: String?
  /// Whether to skip upstream Git repository validation.
  public var skipGitRepoCheck: Bool
  /// Raw `-c` config override arguments.
  public var configOverrides: [String]

  /// Creates shared exec request options.
  public init(
    images: [URL] = [],
    additionalWritableDirectories: [URL] = [],
    approvalMode: String? = nil,
    searchEnabled: Bool? = nil,
    enabledFeatures: [String] = [],
    disabledFeatures: [String] = [],
    model: String? = nil,
    useOSS: Bool = false,
    workingDirectory: URL? = nil,
    colorMode: String? = nil,
    dangerouslyBypassApprovalsAndSandbox: Bool = false,
    ephemeral: Bool = false,
    fullAuto: Bool = false,
    profile: String? = nil,
    sandboxMode: String? = nil,
    skipGitRepoCheck: Bool = false,
    configOverrides: [String] = []
  ) {
    self.init(
      images: images,
      additionalWritableDirectories: additionalWritableDirectories,
      approvalMode: approvalMode,
      searchEnabled: searchEnabled,
      enabledFeatures: enabledFeatures,
      disabledFeatures: disabledFeatures,
      model: model,
      useOSS: useOSS,
      workingDirectory: workingDirectory,
      colorMode: colorMode,
      dangerouslyBypassApprovalsAndSandbox: dangerouslyBypassApprovalsAndSandbox,
      ephemeral: ephemeral,
      ignoreUserConfig: false,
      fullAuto: fullAuto,
      profile: profile,
      sandboxMode: sandboxMode,
      skipGitRepoCheck: skipGitRepoCheck,
      configOverrides: configOverrides
    )
  }

  /// Creates shared exec request options with an explicit user-config policy.
  public init(
    images: [URL] = [],
    additionalWritableDirectories: [URL] = [],
    approvalMode: String? = nil,
    searchEnabled: Bool? = nil,
    enabledFeatures: [String] = [],
    disabledFeatures: [String] = [],
    model: String? = nil,
    useOSS: Bool = false,
    workingDirectory: URL? = nil,
    colorMode: String? = nil,
    dangerouslyBypassApprovalsAndSandbox: Bool = false,
    ephemeral: Bool = false,
    ignoreUserConfig: Bool,
    fullAuto: Bool = false,
    profile: String? = nil,
    sandboxMode: String? = nil,
    skipGitRepoCheck: Bool = false,
    configOverrides: [String] = []
  ) {
    self.images = images
    self.additionalWritableDirectories = additionalWritableDirectories
    self.approvalMode = approvalMode
    self.searchEnabled = searchEnabled
    self.enabledFeatures = enabledFeatures
    self.disabledFeatures = disabledFeatures
    self.model = model
    self.useOSS = useOSS
    self.workingDirectory = workingDirectory
    self.colorMode = colorMode
    self.dangerouslyBypassApprovalsAndSandbox = dangerouslyBypassApprovalsAndSandbox
    self.ephemeral = ephemeral
    self.ignoreUserConfig = ignoreUserConfig
    self.fullAuto = fullAuto
    self.profile = profile
    self.sandboxMode = sandboxMode
    self.skipGitRepoCheck = skipGitRepoCheck
    self.configOverrides = configOverrides
  }
}

/// Prompt and stdin mapping for an upstream exec request.
public enum CodexExecPromptInput: Equatable, Sendable {
  /// Prompt supplied as a positional command argument.
  case text(String)
  /// Stdin supplied with `-` as the positional prompt argument.
  case stdin(String)
  /// Prompt supplied as an argument with additional stdin context.
  case textWithStdinContext(prompt: String, stdin: String)
}

/// Selector for `codex exec resume`.
public enum CodexExecResumeSelector: Equatable, Sendable {
  /// Resume an explicit upstream session id.
  case sessionID(String)
  /// Resume the latest upstream session.
  case last
  /// Resume the latest upstream session across all known workspaces.
  case lastAll
}

/// Output mode requested from upstream exec.
public enum CodexExecOutputMode: Equatable, Sendable {
  /// Human-readable stdout with diagnostics on stderr.
  case humanReadable
  /// JSONL protocol events on stdout.
  case jsonl
}

/// Request for a fresh `codex exec` run.
public struct CodexExecRunRequest: Equatable, Sendable {
  /// Prompt or stdin input supplied to upstream.
  public var promptInput: CodexExecPromptInput
  /// Requested upstream output mode.
  public var outputMode: CodexExecOutputMode
  /// Shared upstream exec options.
  public var options: CodexExecRequestOptions
  /// Optional JSON schema file supplied to upstream.
  public var outputSchemaFile: URL?
  /// Optional output-last-message file to verify after termination.
  public var outputLastMessageFile: URL?

  /// Creates a fresh exec request.
  public init(
    promptInput: CodexExecPromptInput,
    outputMode: CodexExecOutputMode = .humanReadable,
    options: CodexExecRequestOptions = .init(),
    outputSchemaFile: URL? = nil,
    outputLastMessageFile: URL? = nil
  ) {
    self.promptInput = promptInput
    self.outputMode = outputMode
    self.options = options
    self.outputSchemaFile = outputSchemaFile
    self.outputLastMessageFile = outputLastMessageFile
  }
}

/// Request for `codex exec resume`.
public struct CodexExecResumeRequest: Equatable, Sendable {
  /// Resume target selector.
  public var selector: CodexExecResumeSelector
  /// Optional prompt or stdin input supplied to the resumed session.
  public var promptInput: CodexExecPromptInput?
  /// Requested upstream output mode.
  public var outputMode: CodexExecOutputMode
  /// Shared upstream exec options.
  public var options: CodexExecRequestOptions
  /// Optional JSON schema file supplied to upstream.
  public var outputSchemaFile: URL?
  /// Optional output-last-message file to verify after termination.
  public var outputLastMessageFile: URL?

  /// Creates a resume exec request.
  public init(
    selector: CodexExecResumeSelector,
    promptInput: CodexExecPromptInput? = nil,
    outputMode: CodexExecOutputMode = .humanReadable,
    options: CodexExecRequestOptions = .init(),
    outputSchemaFile: URL? = nil,
    outputLastMessageFile: URL? = nil
  ) {
    self.selector = selector
    self.promptInput = promptInput
    self.outputMode = outputMode
    self.options = options
    self.outputSchemaFile = outputSchemaFile
    self.outputLastMessageFile = outputLastMessageFile
  }
}

/// Exec operation kind represented by a launched process.
public enum CodexExecOperation: Equatable, Sendable {
  case run
  case resume
}

/// Normalized process termination status.
public enum CodexExecExitInterpretation: Equatable, Sendable {
  /// The process exited with an exit code.
  case exited(code: Int32)
  /// The process terminated due to a signal.
  case signaled(Int32)
}

/// Final process-level metadata for a completed exec request.
public struct CodexExecTermination: Equatable, Sendable {
  /// Operation that produced this termination.
  public var operation: CodexExecOperation
  /// Working directory used for the launched process.
  public var effectiveWorkingDirectory: URL?
  /// Normalized exit or signal status.
  public var exitInterpretation: CodexExecExitInterpretation
  /// Complete stderr text captured from upstream.
  public var capturedStderrText: String

  /// Creates process termination metadata.
  public init(
    operation: CodexExecOperation,
    effectiveWorkingDirectory: URL?,
    exitInterpretation: CodexExecExitInterpretation,
    capturedStderrText: String = ""
  ) {
    self.operation = operation
    self.effectiveWorkingDirectory = effectiveWorkingDirectory
    self.exitInterpretation = exitInterpretation
    self.capturedStderrText = capturedStderrText
  }
}

/// Stream-first handle for a launched upstream exec process.
public final class CodexExecProcessHandle: @unchecked Sendable {
  /// Raw stdout lines emitted by upstream.
  public let stdoutLines: AsyncThrowingStream<String, Error>

  private let waiter: @Sendable () async throws -> CodexExecTermination

  init(
    stdoutLines: AsyncThrowingStream<String, Error>,
    waiter: @escaping @Sendable () async throws -> CodexExecTermination
  ) {
    self.stdoutLines = stdoutLines
    self.waiter = waiter
  }

  /// Waits for process termination and returns process-level metadata.
  public func waitForTermination() async throws -> CodexExecTermination {
    try await waiter()
  }
}
