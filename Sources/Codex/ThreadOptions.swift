import Foundation

/// Per-thread SDK options translated to upstream exec request options.
public struct ThreadOptions: Equatable, Sendable {
  /// Optional upstream model identifier.
  public var model: String?
  /// Optional upstream sandbox mode value.
  public var sandboxMode: String?
  /// Working directory for turns in this thread.
  public var workingDirectory: URL?
  /// Whether to skip upstream Git repository validation.
  public var skipGitRepoCheck: Bool
  /// Optional upstream reasoning effort value.
  public var modelReasoningEffort: String?
  /// Optional network access setting for workspace-write sandbox config.
  public var networkAccessEnabled: Bool?
  /// Optional upstream web-search mode value.
  public var webSearchMode: String?
  /// Optional upstream approval policy value.
  public var approvalPolicy: String?
  /// Additional writable directories passed to upstream exec.
  public var additionalDirectories: [URL]

  /// Creates per-thread options used for all turns on a thread.
  public init(
    model: String? = nil,
    sandboxMode: String? = nil,
    workingDirectory: URL? = nil,
    skipGitRepoCheck: Bool = false,
    modelReasoningEffort: String? = nil,
    networkAccessEnabled: Bool? = nil,
    webSearchMode: String? = nil,
    approvalPolicy: String? = nil,
    additionalDirectories: [URL] = []
  ) {
    self.model = model
    self.sandboxMode = sandboxMode
    self.workingDirectory = workingDirectory
    self.skipGitRepoCheck = skipGitRepoCheck
    self.modelReasoningEffort = modelReasoningEffort
    self.networkAccessEnabled = networkAccessEnabled
    self.webSearchMode = webSearchMode
    self.approvalPolicy = approvalPolicy
    self.additionalDirectories = additionalDirectories
  }
}
