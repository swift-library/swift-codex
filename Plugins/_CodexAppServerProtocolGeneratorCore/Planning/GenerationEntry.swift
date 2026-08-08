struct GenerationEntry {
  let surface: Surface
  let schemaRelativePath: String
  let typeName: String
  let outputRelativePath: String
  let schema: Any
  let knownTypeNames: Set<String>
  let constructUses: [ConstructUse]
}
