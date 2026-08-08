import Foundation

/// JSON-like value accepted by Codex SDK configuration overrides.
public typealias CodexConfigObject = [String: CodexConfigValue]

/// JSON-compatible configuration value translated to upstream Codex config overrides.
public indirect enum CodexConfigValue: Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([CodexConfigValue])
  case object(CodexConfigObject)
}

/// Process and runtime defaults used by `Codex` SDK clients.
public struct CodexOptions: Equatable, Sendable {
  /// Optional path to the `codex` executable used by the underlying exec layer.
  public var codexPathOverride: URL?
  /// Optional OpenAI-compatible base URL override.
  public var baseURL: URL?
  /// Optional API key passed to the underlying Codex process environment.
  public var apiKey: String?
  /// Config overrides translated to upstream `-c` arguments.
  public var config: CodexConfigObject
  /// Optional environment replacement for launched Codex subprocesses.
  public var environment: [String: String]?

  /// Creates SDK defaults used when starting or resuming threads.
  public init(
    codexPathOverride: URL? = nil,
    baseURL: URL? = nil,
    apiKey: String? = nil,
    config: CodexConfigObject = [:],
    environment: [String: String]? = nil
  ) {
    self.codexPathOverride = codexPathOverride
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.config = config
    self.environment = environment
  }
}
