import Darwin
import Foundation

/// Lifecycle state for a `codex mcp-server` client.
public enum CodexMCPClientState: Equatable, Sendable {
  case idle
  case starting
  case running
  case stopping
  case stopped
  case failed
}

/// Swift client facade for OpenAI Codex's `codex mcp-server` process.
public actor CodexMCPClient {
  /// Public alias for the client lifecycle state type.
  public typealias State = CodexMCPClientState

  /// Launch options used when starting the upstream MCP server process.
  public let launchOptions: CodexMCPLaunchOptions
  /// Caller-supplied identity and requested MCP protocol version.
  public let clientInfo: CodexMCPClientInfo
  /// Current client lifecycle state.
  public internal(set) var state: State

  let lifecycleShellHooks: CodexMCPLifecycleShellHooks
  let subprocessLauncher: CodexMCPSubprocessLauncher
  let requestCancellationState: CodexMCPRequestCancellationState
  var subprocess: CodexMCPManagedSubprocess?
  var protocolAdapter: CodexMCPProtocolClientAdapter?
  var startupTask: Task<Void, Error>?
  var startupMetadata: CodexMCPStartupMetadata?

  /// Creates a Codex MCP client.
  public init(
    clientInfo: CodexMCPClientInfo,
    launchOptions: CodexMCPLaunchOptions = .init()
  ) {
    self.clientInfo = clientInfo
    self.launchOptions = launchOptions
    state = .idle
    lifecycleShellHooks = .none
    subprocessLauncher = .live
    requestCancellationState = .init()
    startupTask = nil
    startupMetadata = nil
  }

  internal init(
    clientInfo: CodexMCPClientInfo,
    launchOptions: CodexMCPLaunchOptions = .init(),
    lifecycleShellHooks: CodexMCPLifecycleShellHooks = .none,
    subprocessLauncher: CodexMCPSubprocessLauncher = .live,
  ) {
    self.clientInfo = clientInfo
    self.launchOptions = launchOptions
    state = .idle
    self.lifecycleShellHooks = lifecycleShellHooks
    self.subprocessLauncher = subprocessLauncher
    requestCancellationState = .init()
    startupTask = nil
    startupMetadata = nil
  }

  deinit {
    let protocolAdapter = protocolAdapter
    let subprocess = subprocess
    subprocess?.closeIO()
    Task {
      await protocolAdapter?.stop()
      try? await subprocess?.terminate()
    }
  }
}
