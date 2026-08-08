/// Per-turn SDK options translated to a single upstream exec request.
public struct TurnOptions: Equatable, Sendable {
  /// Optional JSON schema used for structured output.
  public var outputSchema: CodexConfigObject?

  /// Creates per-turn options.
  public init(outputSchema: CodexConfigObject? = nil) {
    self.outputSchema = outputSchema
  }
}
