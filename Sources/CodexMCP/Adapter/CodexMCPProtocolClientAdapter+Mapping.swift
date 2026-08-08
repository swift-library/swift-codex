import Foundation
import MCP

func mcpArgumentObject<Arguments: Codable>(from arguments: Arguments) throws -> [String: MCP.Value]
{
  let value: MCP.Value
  do {
    value = try MCP.Value(arguments)
  } catch {
    throw CodexMCPError.protocolFailure
  }

  guard let object = value.objectValue else {
    throw CodexMCPError.protocolFailure
  }

  return object
}

func toolDescriptor(from tool: MCP.Tool) throws -> CodexMCPToolDescriptor {
  guard let inputSchemaObject = codexValue(from: tool.inputSchema).objectValue else {
    throw CodexMCPError.protocolFailure
  }

  let outputSchema: [String: CodexMCPJSONValue]?
  if let mcpOutputSchema = tool.outputSchema {
    guard let outputSchemaObject = codexValue(from: mcpOutputSchema).objectValue else {
      throw CodexMCPError.protocolFailure
    }
    outputSchema = outputSchemaObject
  } else {
    outputSchema = nil
  }

  return CodexMCPToolDescriptor(
    name: tool.name,
    title: tool.title,
    description: tool.description,
    inputSchema: inputSchemaObject,
    outputSchema: outputSchema,
  )
}

func mapMCPError(_ error: Error, fallback: CodexMCPError) -> CodexMCPError {
  if let codexError = error as? CodexMCPError {
    return codexError
  }

  if error is CancellationError {
    return .transportFailure
  }

  guard let mcpError = error as? MCP.MCPError else {
    return fallback
  }

  switch mcpError {
  case .parseError, .invalidRequest, .invalidParams:
    return .protocolFailure
  case .methodNotFound, .internalError, .serverError, .urlElicitationRequired:
    return .jsonrpcFailure(
      .init(
        code: mcpError.code,
        message: mcpError.errorDescription ?? "JSON-RPC error"
      ))
  case .connectionClosed, .transportError:
    return .transportFailure
  }
}

func mcpID(from requestID: CodexMCPRequestID) -> MCP.ID {
  switch requestID {
  case .integer(let integer):
    guard let number = Int(exactly: integer) else {
      preconditionFailure("MCP SDK ID cannot represent Int64 request ID \(integer)")
    }
    return .number(number)
  case .string(let string):
    return .string(string)
  }
}

func requestID(from value: CodexMCPJSONValue?) -> CodexMCPRequestID? {
  switch value {
  case .string(let string):
    return .string(string)
  case .integer(let integer):
    return .integer(integer)
  default:
    return nil
  }
}

internal func codexValue(from value: MCP.Value) -> CodexMCPJSONValue {
  switch value {
  case .null:
    return .null
  case .bool(let bool):
    return .bool(bool)
  case .int(let int):
    return .integer(Int64(int))
  case .double(let double):
    return .double(double)
  case .string(let string):
    return .string(string)
  case .data(_, let data):
    return .string(data.base64EncodedString())
  case .array(let array):
    return .array(array.map(codexValue(from:)))
  case .object(let object):
    return .object(object.mapValues(codexValue(from:)))
  }
}
