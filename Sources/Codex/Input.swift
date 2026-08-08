import Foundation

/// Input accepted by an SDK turn.
public enum Input: Equatable, Sendable {
  /// Plain text prompt input.
  case text(String)
  /// Structured user input parts.
  case items([UserInput])
}

/// User-authored input part forwarded to the underlying exec request.
public enum UserInput: Equatable, Sendable {
  /// Text input part.
  case text(String)
  /// Local image path passed as an upstream image argument.
  case localImage(URL)
}
