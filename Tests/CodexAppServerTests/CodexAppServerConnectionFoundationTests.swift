import CodexAppServerTestingSupport
import Foundation
import Testing

@testable import CodexAppServerClient
@testable import CodexAppServerProtocol
@testable import CodexAppServerRuntime
@testable import CodexAppServerStdio

@Suite("CodexAppServer Connection Foundation")
struct CodexAppServerConnectionFoundationTests {
  @Test("Stdio frame codec preserves newline-delimited JSON boundaries")
  func stdioFrameCodecPreservesNewlineDelimitedJSONBoundaries() throws {
    var codec = CodexAppServerConnectionFoundation.StdioFrameCodec()
    let firstChunk = Data("{\"id\":1,\"method\":\"initialize\"".utf8)
    let secondChunk = Data("}\n{\"method\":\"initialized\"}\r\n".utf8)

    #expect(try codec.appendIncoming(firstChunk).isEmpty)
    #expect(codec.hasPendingPartialLine)

    let lines = try codec.appendIncoming(secondChunk)
    #expect(
      lines == [
        #"{"id":1,"method":"initialize"}"#,
        #"{"method":"initialized"}"#,
      ])
    #expect(!codec.hasPendingPartialLine)

    let encoded = try codec.encodeOutgoingLine(#"{"method":"initialized"}"#)
    #expect(encoded == Data("{\"method\":\"initialized\"}\n".utf8))
  }

  @Test("Stdio frame codec rejects invalid UTF-8 and embedded newline output")
  func stdioFrameCodecRejectsInvalidUTF8AndEmbeddedNewlineOutput() throws {
    var codec = CodexAppServerConnectionFoundation.StdioFrameCodec()

    do {
      _ = try codec.appendIncoming(Data([0xFF, 0x0A]))
      Issue.record("Expected invalid UTF-8 to fail.")
    } catch let error as CodexAppServerConnectionFoundation.FoundationError {
      #expect(error == .invalidUTF8)
    }

    do {
      _ = try codec.encodeOutgoingLine("{\"method\":\"a\"}\n{\"method\":\"b\"}")
      Issue.record("Expected embedded newline to fail.")
    } catch let error as CodexAppServerConnectionFoundation.FoundationError {
      #expect(error == .embeddedNewline)
    }
  }

  @Test("Request IDs preserve JSON-RPC string and integer forms")
  func requestIDsPreserveJSONRPCStringAndIntegerForms() throws {
    #expect(
      try decode(CodexAppServerConnectionFoundation.RequestID.self, from: #"1"#) == .integer(1))
    #expect(
      try decode(CodexAppServerConnectionFoundation.RequestID.self, from: #""approval-1""#)
        == .string("approval-1")
    )

    #expect(try encode(CodexAppServerConnectionFoundation.RequestID.integer(7)) == "7")
    #expect(try encode(CodexAppServerConnectionFoundation.RequestID.string("r-7")) == #""r-7""#)
  }

  @Test("JSON values preserve raw dynamic payloads")
  func jsonValuesPreserveRawDynamicPayloads() throws {
    let value = try decode(
      CodexAppServerConnectionFoundation.JSONValue.self,
      from: #"{"items":[1,true,null,"x"],"thread":{"id":"thread-1"}}"#
    )

    #expect(
      value
        == .object([
          "items": .array([.number(1), .bool(true), .null, .string("x")]),
          "thread": .object(["id": .string("thread-1")]),
        ]))
  }

  @Test("JSON values preserve large integer precision")
  func jsonValuesPreserveLargeIntegerPrecision() throws {
    let raw = "9007199254740993"
    let value = try decode(CodexAppServerConnectionFoundation.JSONValue.self, from: raw)

    #expect(value == .number(.integer(9_007_199_254_740_993)))
    #expect(try encode(value) == raw)
  }

  @Test("Raw envelopes classify request, notification, success, and failure messages")
  func rawEnvelopesClassifyJSONRPCMessageFamilies() throws {
    let request = try CodexAppServerConnectionFoundation.decodeLine(
      #"{"id":1,"method":"thread/start","params":{"cwd":"/tmp/swift-codex"}}"#
    )
    #expect(
      try request.classify()
        == .request(
          id: .integer(1),
          method: "thread/start",
          params: .object(["cwd": .string("/tmp/swift-codex")])
        ))

    let notification = try CodexAppServerConnectionFoundation.decodeLine(
      #"{"method":"initialized"}"#
    )
    #expect(
      try notification.classify()
        == .notification(
          method: "initialized",
          params: nil
        ))

    let success = try CodexAppServerConnectionFoundation.decodeLine(
      #"{"id":"request-1","result":null}"#
    )
    #expect(
      try success.classify()
        == .success(
          id: .string("request-1"),
          result: .null
        ))

    let failure = try CodexAppServerConnectionFoundation.decodeLine(
      #"{"id":2,"error":{"code":-32600,"message":"Not initialized","data":null}}"#
    )
    #expect(
      try failure.classify()
        == .failure(
          id: .integer(2),
          error: .init(code: -32600, message: "Not initialized", data: .null)
        ))
  }

  @Test("Raw envelope rejects malformed message families")
  func rawEnvelopeRejectsMalformedMessageFamilies() throws {
    let invalidVersion = try CodexAppServerConnectionFoundation.decodeLine(
      #"{"jsonrpc":"1.0","method":"initialized"}"#
    )
    do {
      _ = try invalidVersion.classify()
      Issue.record("Expected invalid JSON-RPC version to fail.")
    } catch let error as CodexAppServerConnectionFoundation.FoundationError {
      #expect(error == .invalidEnvelope)
    }

    let ambiguous = try CodexAppServerConnectionFoundation.decodeLine(
      #"{"id":1,"result":{},"error":{"code":-32603,"message":"Internal error"}}"#
    )
    do {
      _ = try ambiguous.classify()
      Issue.record("Expected result+error envelope to fail.")
    } catch let error as CodexAppServerConnectionFoundation.FoundationError {
      #expect(error == .invalidEnvelope)
    }
  }

}
private func decode<T: Decodable>(_ type: T.Type, from rawJSON: String) throws -> T {
  let data = Data(rawJSON.utf8)
  return try JSONDecoder().decode(type, from: data)
}

private func encode<T: Encodable>(_ value: T) throws -> String {
  let data = try JSONEncoder().encode(value)
  return String(decoding: data, as: UTF8.self)
}
