/// Upstream-aligned SDK entry point for `swift-codex`.
public final class Codex: Sendable {
  /// Process and runtime defaults shared by threads created from this client.
  public let options: CodexOptions

  /// Creates an SDK client with optional process and configuration defaults.
  public init(options: CodexOptions = .init()) {
    self.options = options
  }

  /// Creates a new thread object whose first turn will start a fresh upstream session.
  public func startThread(options: ThreadOptions = .init()) -> CodexThread {
    CodexThread(id: nil, threadOptions: options, clientOptions: self.options)
  }

  /// Creates a thread object bound to an existing upstream session identifier.
  public func resumeThread(_ id: String, options: ThreadOptions = .init()) -> CodexThread {
    CodexThread(id: id, threadOptions: options, clientOptions: self.options)
  }
}
