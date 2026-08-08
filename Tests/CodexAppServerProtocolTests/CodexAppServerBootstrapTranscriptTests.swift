import CodexAppServerTestingSupport
import Foundation
import Testing

@Suite("CodexAppServer Bootstrap Transcript")
struct CodexAppServerBootstrapTranscriptTests {
  @Test("Bootstrap success transcript preserves initialize response then initialized")
  func bootstrapSuccessTranscriptReplaysFullHandshakeSequence() throws {
    let transcript = CodexAppServerBootstrapTranscripts.bootstrapSuccess

    #expect(transcript.messages.count == 3)
    #expect(transcript.messages[0].direction == .clientToServer)
    #expect(transcript.messages[1].direction == .serverToClient)
    #expect(transcript.messages[2].direction == .clientToServer)
    let initializeRequest = try decodeObject(fromLine: transcript.messages[0].line)
    #expect(initializeRequest["method"] as? String == "initialize")

    var replay = transcript.makeReplay()

    try replay.sendClientLine(transcript.messages[0].line.encoded)

    let responseObject = try decodeObject(fromEncodedLine: replay.receiveServerLine())
    #expect(intValue(responseObject["id"]) == 1)
    #expect(responseObject["error"] == nil)
    let resultObject = try requireObject(responseObject["result"], name: "initialize.result")
    #expect(resultObject["codexHome"] as? String == "/tmp/swift-codex/codex-home")
    #expect(resultObject["platformFamily"] as? String == "unix")
    #expect(resultObject["platformOs"] as? String == "macos")
    #expect(resultObject["userAgent"] as? String == "Codex/swift-codex-bootstrap-fixture")

    let initializedNotification = try decodeObject(fromLine: transcript.messages[2].line)
    #expect(initializedNotification["method"] as? String == "initialized")
    #expect(initializedNotification["params"] == nil)
    try replay.sendClientLine(transcript.messages[2].line.encoded)
    try replay.finish()
  }

  @Test("Request-before-initialize transcript matches upstream invalid-request failure")
  func requestBeforeInitializeTranscriptMatchesUpstreamFailure() throws {
    let transcript = CodexAppServerBootstrapTranscripts.requestBeforeInitializeFailure

    #expect(transcript.sourceEvidence.contains("codex-rs/app-server/src/message_processor.rs"))
    #expect(transcript.messages.count == 2)
    #expect(transcript.messages[0].direction == .clientToServer)
    #expect(transcript.messages[1].direction == .serverToClient)

    let requestObject = try decodeObject(fromLine: transcript.messages[0].line)
    #expect(requestObject["method"] as? String == "config/read")
    let requestParams = try requireObject(requestObject["params"], name: "config/read.params")
    #expect(boolValue(requestParams["includeLayers"]) == false)

    var replay = transcript.makeReplay()
    try replay.sendClientLine(transcript.messages[0].line.encoded)

    let failureObject = try decodeObject(fromEncodedLine: replay.receiveServerLine())
    #expect(intValue(failureObject["id"]) == 2)
    #expect(failureObject["result"] == nil)

    let errorObject = try requireObject(failureObject["error"], name: "error")
    #expect(intValue(errorObject["code"]) == -32600)
    #expect(errorObject["message"] as? String == "Not initialized")
    #expect(errorObject["data"] == nil)

    try replay.finish()
  }

  @Test("Double-initialize transcript matches upstream invalid-request failure")
  func doubleInitializeTranscriptMatchesUpstreamFailure() throws {
    let transcript = CodexAppServerBootstrapTranscripts.doubleInitializeFailure
    #expect(transcript.messages.count == 5)
    #expect(
      transcript.messages.map(\.direction) == [
        .clientToServer,
        .serverToClient,
        .clientToServer,
        .clientToServer,
        .serverToClient,
      ])

    let firstInitializeRequest = try decodeObject(fromLine: transcript.messages[0].line)
    #expect(firstInitializeRequest["method"] as? String == "initialize")
    let initializedNotification = try decodeObject(fromLine: transcript.messages[2].line)
    #expect(initializedNotification["method"] as? String == "initialized")
    #expect(initializedNotification["params"] == nil)
    let secondInitializeRequest = try decodeObject(fromLine: transcript.messages[3].line)
    #expect(secondInitializeRequest["method"] as? String == "initialize")

    var replay = transcript.makeReplay()

    try replay.sendClientLine(transcript.messages[0].line.encoded)
    let initialResponseObject = try decodeObject(fromEncodedLine: replay.receiveServerLine())
    #expect(intValue(initialResponseObject["id"]) == 1)
    #expect(initialResponseObject["error"] == nil)
    let initialResultObject = try requireObject(
      initialResponseObject["result"],
      name: "initial initialize.result"
    )
    #expect(initialResultObject["codexHome"] as? String == "/tmp/swift-codex/codex-home")
    #expect(initialResultObject["platformFamily"] as? String == "unix")
    #expect(initialResultObject["platformOs"] as? String == "macos")
    #expect(initialResultObject["userAgent"] as? String == "Codex/swift-codex-bootstrap-fixture")
    try replay.sendClientLine(transcript.messages[2].line.encoded)
    try replay.sendClientLine(transcript.messages[3].line.encoded)

    let failureObject = try decodeObject(fromEncodedLine: replay.receiveServerLine())
    #expect(intValue(failureObject["id"]) == 3)
    #expect(failureObject["result"] == nil)

    let errorObject = try requireObject(failureObject["error"], name: "error")
    #expect(intValue(errorObject["code"]) == -32600)
    #expect(errorObject["message"] as? String == "Already initialized")
    #expect(errorObject["data"] == nil)

    try replay.finish()
  }

  @Test("JSON-RPC line codec enforces newline-delimited object messages")
  func jsonRPCLineCodecEnforcesNewlineDelimitedObjects() throws {
    let line = try CodexAppServerBootstrapTranscripts.JSONRPCLine(
      rawObject: #"{"method":"initialized"}"#
    )
    #expect(line.encoded == "{\"method\":\"initialized\"}\n")

    let roundTripped = try CodexAppServerBootstrapTranscripts.JSONRPCLine(encoded: line.encoded)
    #expect(roundTripped == line)

    do {
      _ = try CodexAppServerBootstrapTranscripts.JSONRPCLine(encoded: line.rawObject)
      Issue.record("Expected missing trailing newline to fail.")
    } catch let error as CodexAppServerBootstrapTranscripts.TranscriptError {
      #expect(error == .missingTrailingNewline)
    }

    do {
      _ = try CodexAppServerBootstrapTranscripts.JSONRPCLine(
        rawObject: "{\"method\":\"initialize\"}\n{\"method\":\"initialized\"}"
      )
      Issue.record("Expected embedded newline to fail.")
    } catch let error as CodexAppServerBootstrapTranscripts.TranscriptError {
      #expect(error == .embeddedNewline)
    }
  }

}
private func decodeObject(fromEncodedLine encodedLine: String) throws -> [String: Any] {
  let line = try CodexAppServerBootstrapTranscripts.JSONRPCLine(encoded: encodedLine)
  return try decodeObject(fromLine: line)
}

private func decodeObject(
  fromLine line: CodexAppServerBootstrapTranscripts.JSONRPCLine
) throws -> [String: Any] {
  guard let data = line.rawObject.data(using: .utf8) else {
    throw DecodingFailure.invalidUTF8
  }

  let value = try JSONSerialization.jsonObject(with: data)
  guard let object = value as? [String: Any] else {
    throw DecodingFailure.notObject
  }

  return object
}

private func requireObject(_ value: Any?, name: String) throws -> [String: Any] {
  guard let object = value as? [String: Any] else {
    throw DecodingFailure.missingObject(name)
  }

  return object
}

private func intValue(_ value: Any?) -> Int? {
  if let value = value as? Int {
    return value
  }

  return (value as? NSNumber)?.intValue
}

private func boolValue(_ value: Any?) -> Bool? {
  if let value = value as? Bool {
    return value
  }

  return (value as? NSNumber)?.boolValue
}

private enum DecodingFailure: Error {
  case invalidUTF8
  case notObject
  case missingObject(String)
}
