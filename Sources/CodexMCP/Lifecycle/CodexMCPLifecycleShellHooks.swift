/// Internal test-support hooks for observing lifecycle transitions in the shell slice.
internal struct CodexMCPLifecycleShellHooks: Sendable {
  var onStartTransition: (@Sendable () async throws -> Void)?
  var onStopTransition: (@Sendable () async throws -> Void)?

  static let none = Self()
}
