import CodexAppServerRuntime
import Foundation

/// A bounded, value-free observation of an inbound JSON-RPC method that the
/// pinned typed client cannot handle.
public struct CodexAppServerUnhandledInboundMessage: Equatable, Sendable {
  public enum Kind: String, Equatable, Sendable {
    case notification
    case rejectedRequest
  }

  public enum MethodStatus: String, Equatable, Sendable {
    case unknown
    case experimentalOnly
  }

  public struct ParameterSummary: Equatable, Sendable {
    public enum Shape: String, Equatable, Sendable {
      case missing
      case null
      case bool
      case number
      case string
      case array
      case object
    }

    public let shape: Shape

    /// Object field count, array element count, or string UTF-8 byte count.
    /// Scalar and missing parameters report `nil`.
    public let valueCount: Int?

    package init(_ value: CodexAppServerConnectionFoundation.JSONValue?) {
      switch value {
      case nil:
        self.init(shape: .missing, valueCount: nil)
      case .some(.null):
        self.init(shape: .null, valueCount: nil)
      case .some(.bool):
        self.init(shape: .bool, valueCount: nil)
      case .some(.number):
        self.init(shape: .number, valueCount: nil)
      case .some(.string(let value)):
        self.init(shape: .string, valueCount: value.utf8.count)
      case .some(.array(let value)):
        self.init(shape: .array, valueCount: value.count)
      case .some(.object(let value)):
        self.init(shape: .object, valueCount: value.count)
      }
    }

    private init(shape: Shape, valueCount: Int?) {
      self.shape = shape
      self.valueCount = valueCount
    }
  }

  public let kind: Kind
  public let methodStatus: MethodStatus

  /// The method name, limited to 256 UTF-8 bytes.
  public let method: String
  public let methodWasTruncated: Bool
  public let parameters: ParameterSummary

  /// Size of the complete inbound JSON-RPC line without retaining its values.
  public let messageByteCount: Int

  package init(
    kind: Kind,
    methodStatus: MethodStatus,
    method: String,
    params: CodexAppServerConnectionFoundation.JSONValue?,
    messageByteCount: Int
  ) {
    let methodLimit = 256
    self.kind = kind
    self.methodStatus = methodStatus
    var methodBytes = Array(method.utf8.prefix(methodLimit))
    while String(bytes: methodBytes, encoding: .utf8) == nil { methodBytes.removeLast() }
    self.method = String(decoding: methodBytes, as: UTF8.self)
    self.methodWasTruncated = method.utf8.count > methodLimit
    self.parameters = ParameterSummary(params)
    self.messageByteCount = messageByteCount
  }
}
