import Foundation

struct GenerationPlan {
  let outputRoot: URL
  let entries: [GenerationEntry]
  let constructUses: [ConstructUse]

  var unsupportedConstructUses: [ConstructUse] {
    constructUses.filter { SchemaConstructMapping.policy(for: $0.construct) == nil }
  }

  func textSummary() -> String {
    var lines: [String] = []
    lines.append("CodexAppServer protocol model generation plan")
    lines.append("outputRoot: \(outputRoot.path)")
    lines.append("types: \(entries.count)")
    for surface in Surface.allCases {
      lines.append("\(surface.rawValue): \(entries.filter { $0.surface == surface }.count)")
    }

    let constructCounts = Dictionary(grouping: constructUses, by: \.construct)
      .mapValues(\.count)
      .sorted { lhs, rhs in lhs.key.rawValue < rhs.key.rawValue }
    if constructCounts.isEmpty {
      lines.append("mappedConstructs: none")
    } else {
      lines.append("mappedConstructs:")
      for (construct, count) in constructCounts {
        let status = SchemaConstructMapping.policy(for: construct) == nil ? "unsupported" : "mapped"
        lines.append("- \(construct.rawValue): \(count) (\(status))")
      }
    }
    let unsupported = unsupportedConstructUses
    lines.append(
      "unsupportedConstructs: \(unsupported.isEmpty ? "none" : String(unsupported.count))")
    lines.append("sampleOutputs:")
    for entry in entries.prefix(12) {
      lines.append("- \(entry.schemaRelativePath) -> \(entry.outputRelativePath)")
    }
    return lines.joined(separator: "\n")
  }

  func validateForGeneration() throws {
    let unsupported = unsupportedConstructUses
    guard unsupported.isEmpty else {
      let examples = unsupported.prefix(20).map {
        "  - \($0.schemaPath)\($0.pointer): \($0.construct.rawValue)"
      }.joined(separator: "\n")
      throw GeneratorError.unsupportedSchemaConstructs(
        """
        unsupported JSON Schema constructs remain; refusing to generate Swift rather than collapsing protocol models to raw JSON
        \(examples)
        """)
    }
  }
}
