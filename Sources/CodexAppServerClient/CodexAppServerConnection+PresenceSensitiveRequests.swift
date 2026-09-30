import CodexAppServerProtocol

/// Exact mutation intent for a synchronized Thread Section appearance.
///
/// The app-server wire distinguishes an omitted field from an explicit JSON
/// null. A plain Swift `Optional` cannot preserve that distinction when used
/// with synthesized `Encodable` conformance.
public enum CodexAppServerThreadSectionAppearanceUpdate: Equatable, Sendable {
  case unchanged
  case clear
  case replace(CodexAppServerProtocol.Stable.ThreadSectionAppearance)
}

/// Exact mutation intent for the service tier of a running Turn.
///
/// The app-server wire uses omission to preserve the current tier and JSON
/// null to clear it. A plain Swift `Optional` cannot encode both states.
public enum CodexAppServerTurnServiceTierUpdate: Equatable, Sendable {
  case unchanged
  case clear
  case replace(String)
}

extension CodexAppServerConnection {
  /// Updates a Thread Section without collapsing preserve and clear semantics.
  public func threadSectionUpdate(
    sectionID: String,
    name: String,
    appearanceUpdate: CodexAppServerThreadSectionAppearanceUpdate
  ) async throws -> CodexAppServerProtocol.Stable.ThreadSectionUpdateResponse {
    try await sendStableRequest(
      method: "threadSection/update",
      params: PresenceSensitiveThreadSectionUpdateParams(
        sectionID: sectionID,
        name: name,
        appearanceUpdate: appearanceUpdate
      ),
      responseType: CodexAppServerProtocol.Stable.ThreadSectionUpdateResponse.self
    )
  }

  /// Updates the settings of a running Turn without collapsing the service
  /// tier's preserve and clear semantics.
  public func turnSettingsUpdate(
    threadID: String,
    turnID: String,
    effort: CodexAppServerProtocol.Experimental.ReasoningEffort? = nil,
    model: String? = nil,
    summary: CodexAppServerProtocol.Experimental.ReasoningSummary? = nil,
    serviceTierUpdate: CodexAppServerTurnServiceTierUpdate = .unchanged
  ) async throws -> CodexAppServerProtocol.Experimental.TurnSettingsUpdateResponse {
    try await sendStableRequest(
      method: "turn/settings/update",
      params: PresenceSensitiveTurnSettingsUpdateParams(
        threadID: threadID,
        turnID: turnID,
        effort: effort,
        model: model,
        summary: summary,
        serviceTierUpdate: serviceTierUpdate
      ),
      responseType: CodexAppServerProtocol.Experimental.TurnSettingsUpdateResponse.self
    )
  }
}

private struct PresenceSensitiveThreadSectionUpdateParams: Encodable, Sendable {
  let sectionID: String
  let name: String
  let appearanceUpdate: CodexAppServerThreadSectionAppearanceUpdate

  private enum CodingKeys: String, CodingKey {
    case appearance
    case name
    case sectionID = "sectionId"
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(name, forKey: .name)
    try container.encode(sectionID, forKey: .sectionID)
    switch appearanceUpdate {
    case .unchanged:
      break
    case .clear:
      try container.encodeNil(forKey: .appearance)
    case .replace(let appearance):
      try container.encode(appearance, forKey: .appearance)
    }
  }
}

private struct PresenceSensitiveTurnSettingsUpdateParams: Encodable, Sendable {
  let threadID: String
  let turnID: String
  let effort: CodexAppServerProtocol.Experimental.ReasoningEffort?
  let model: String?
  let summary: CodexAppServerProtocol.Experimental.ReasoningSummary?
  let serviceTierUpdate: CodexAppServerTurnServiceTierUpdate

  private enum CodingKeys: String, CodingKey {
    case effort
    case model
    case serviceTier
    case summary
    case threadID = "threadId"
    case turnID = "turnId"
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(effort, forKey: .effort)
    try container.encodeIfPresent(model, forKey: .model)
    try container.encodeIfPresent(summary, forKey: .summary)
    try container.encode(threadID, forKey: .threadID)
    try container.encode(turnID, forKey: .turnID)
    switch serviceTierUpdate {
    case .unchanged:
      break
    case .clear:
      try container.encodeNil(forKey: .serviceTier)
    case .replace(let serviceTier):
      try container.encode(serviceTier, forKey: .serviceTier)
    }
  }
}
