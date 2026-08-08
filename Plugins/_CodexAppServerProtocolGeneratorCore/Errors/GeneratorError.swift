enum GeneratorError: Error, CustomStringConvertible {
  case usage(String)
  case missingInput(String)
  case invalidSchema(String)
  case unsupportedClassification(String)
  case unsupportedSchemaConstructs(String)
  case emissionNotImplemented(String)

  var description: String {
    switch self {
    case .usage(let message),
      .missingInput(let message),
      .invalidSchema(let message),
      .unsupportedClassification(let message),
      .unsupportedSchemaConstructs(let message),
      .emissionNotImplemented(let message):
      return message
    }
  }
}
