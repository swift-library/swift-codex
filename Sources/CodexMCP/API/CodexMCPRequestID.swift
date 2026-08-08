/// JSON-RPC request identifier used by the Codex MCP public API.
public enum CodexMCPRequestID: Hashable, Sendable {
  /// Exact signed 64-bit integer request identifier.
  case integer(Int64)
  /// String request identifier.
  case string(String)
}
