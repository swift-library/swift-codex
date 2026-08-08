import Foundation

internal struct CodexMCPStartupMetadata: Equatable, Sendable {
  let protocolVersion: String
  let serverInfo: CodexMCPServerInfo
}

internal struct CodexMCPServerInfo: Equatable, Sendable {
  let name: String
  let title: String?
  let version: String
  let userAgent: String?
}
