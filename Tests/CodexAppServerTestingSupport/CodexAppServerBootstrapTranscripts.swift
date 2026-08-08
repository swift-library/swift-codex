import Foundation

public enum CodexAppServerBootstrapTranscripts {
  public enum Direction: Equatable, Sendable {
    case clientToServer
    case serverToClient
  }

  public enum TranscriptError: Error, Equatable, Sendable {
    case missingTrailingNewline
    case embeddedNewline
    case invalidJSON(String)
    case nonObjectJSON
    case transcriptExhausted
    case unexpectedDirection(expected: Direction, actual: Direction)
    case unexpectedLine(expected: String, actual: String)
    case transcriptNotFullyConsumed(remaining: Int)
  }

  public struct JSONRPCLine: Equatable, Sendable {
    public let rawObject: String

    public init(rawObject: String) throws {
      self.rawObject = try Self.normalize(rawObject)
    }

    public init(encoded: String) throws {
      guard encoded.hasSuffix("\n") else {
        throw TranscriptError.missingTrailingNewline
      }

      let rawObject = String(encoded.dropLast())
      guard !rawObject.contains("\n") else {
        throw TranscriptError.embeddedNewline
      }

      try self.init(rawObject: rawObject)
    }

    public var encoded: String {
      rawObject + "\n"
    }

    private static func normalize(_ rawObject: String) throws -> String {
      guard !rawObject.contains("\n") else {
        throw TranscriptError.embeddedNewline
      }

      guard let data = rawObject.data(using: .utf8) else {
        throw TranscriptError.invalidJSON("Line is not valid UTF-8.")
      }

      let value: Any
      do {
        value = try JSONSerialization.jsonObject(with: data)
      } catch {
        throw TranscriptError.invalidJSON(error.localizedDescription)
      }

      guard let object = value as? [String: Any] else {
        throw TranscriptError.nonObjectJSON
      }

      let normalizedData: Data
      do {
        normalizedData = try JSONSerialization.data(
          withJSONObject: object,
          options: [.sortedKeys]
        )
      } catch {
        throw TranscriptError.invalidJSON(error.localizedDescription)
      }

      guard let normalized = String(data: normalizedData, encoding: .utf8) else {
        throw TranscriptError.invalidJSON("Normalized JSON was not valid UTF-8.")
      }

      return normalized
    }
  }

  public struct Message: Equatable, Sendable {
    public let direction: Direction
    public let line: JSONRPCLine

    public init(direction: Direction, line: JSONRPCLine) {
      self.direction = direction
      self.line = line
    }
  }

  public struct Transcript: Equatable, Sendable {
    public let name: String
    public let sourceEvidence: [String]
    public let messages: [Message]

    public init(name: String, sourceEvidence: [String], messages: [Message]) {
      self.name = name
      self.sourceEvidence = sourceEvidence
      self.messages = messages
    }

    public func makeReplay() -> Replay {
      Replay(transcript: self)
    }
  }

  public struct Replay: Sendable {
    private var remainingMessages: ArraySlice<Message>

    public init(transcript: Transcript) {
      remainingMessages = ArraySlice(transcript.messages)
    }

    public var hasRemainingMessages: Bool {
      !remainingMessages.isEmpty
    }

    public mutating func sendClientLine(_ encodedLine: String) throws {
      let actualLine = try JSONRPCLine(encoded: encodedLine)
      try consume(expectedDirection: .clientToServer, actualLine: actualLine)
    }

    public mutating func receiveServerLine() throws -> String {
      guard let nextMessage = remainingMessages.first else {
        throw TranscriptError.transcriptExhausted
      }

      guard nextMessage.direction == .serverToClient else {
        throw TranscriptError.unexpectedDirection(
          expected: .serverToClient,
          actual: nextMessage.direction
        )
      }

      remainingMessages = remainingMessages.dropFirst()
      return nextMessage.line.encoded
    }

    public mutating func finish() throws {
      guard remainingMessages.isEmpty else {
        throw TranscriptError.transcriptNotFullyConsumed(remaining: remainingMessages.count)
      }
    }

    private mutating func consume(expectedDirection: Direction, actualLine: JSONRPCLine) throws {
      guard let nextMessage = remainingMessages.first else {
        throw TranscriptError.transcriptExhausted
      }

      guard nextMessage.direction == expectedDirection else {
        throw TranscriptError.unexpectedDirection(
          expected: expectedDirection,
          actual: nextMessage.direction
        )
      }

      guard nextMessage.line == actualLine else {
        throw TranscriptError.unexpectedLine(
          expected: nextMessage.line.rawObject,
          actual: actualLine.rawObject
        )
      }

      remainingMessages = remainingMessages.dropFirst()
    }
  }

  public static let bootstrapSuccess = makeTranscript(
    name: "bootstrap-success",
    messages: [
      .init(
        direction: .clientToServer,
        line: makeRequest(
          id: 1,
          method: "initialize",
          params: [
            "clientInfo": [
              "name": "swift_codex_tests",
              "title": "swift-codex AppServer Tests",
              "version": "0.1.0",
            ],
            "capabilities": [
              "experimentalApi": false,
              "optOutNotificationMethods": ["thread/started"],
            ],
          ]
        )
      ),
      .init(
        direction: .serverToClient,
        line: makeResponse(
          id: 1,
          result: [
            "userAgent": "Codex/swift-codex-bootstrap-fixture",
            "codexHome": "/tmp/swift-codex/codex-home",
            "platformFamily": "unix",
            "platformOs": "macos",
          ]
        )
      ),
      .init(
        direction: .clientToServer,
        line: makeNotification(method: "initialized")
      ),
    ]
  )

  public static let requestBeforeInitializeFailure = makeTranscript(
    name: "request-before-initialize-failure",
    messages: [
      .init(
        direction: .clientToServer,
        line: makeRequest(
          id: 2,
          method: "config/read",
          params: ["includeLayers": false]
        )
      ),
      .init(
        direction: .serverToClient,
        line: makeError(
          id: 2,
          code: -32600,
          message: "Not initialized"
        )
      ),
    ]
  )

  public static let doubleInitializeFailure = makeTranscript(
    name: "double-initialize-failure",
    messages: [
      .init(
        direction: .clientToServer,
        line: makeRequest(
          id: 1,
          method: "initialize",
          params: [
            "clientInfo": [
              "name": "swift_codex_tests",
              "title": "swift-codex AppServer Tests",
              "version": "0.1.0",
            ]
          ]
        )
      ),
      .init(
        direction: .serverToClient,
        line: makeResponse(
          id: 1,
          result: [
            "userAgent": "Codex/swift-codex-bootstrap-fixture",
            "codexHome": "/tmp/swift-codex/codex-home",
            "platformFamily": "unix",
            "platformOs": "macos",
          ]
        )
      ),
      .init(
        direction: .clientToServer,
        line: makeNotification(method: "initialized")
      ),
      .init(
        direction: .clientToServer,
        line: makeRequest(
          id: 3,
          method: "initialize",
          params: [
            "clientInfo": [
              "name": "swift_codex_tests",
              "title": "swift-codex AppServer Tests",
              "version": "0.1.0",
            ]
          ]
        )
      ),
      .init(
        direction: .serverToClient,
        line: makeError(
          id: 3,
          code: -32600,
          message: "Already initialized"
        )
      ),
    ]
  )

  private static let bootstrapSourceEvidence = [
    "codex-rs/app-server/README.md",
    "codex-rs/app-server/src/message_processor.rs",
    "codex-rs/app-server-protocol/src/protocol/v1.rs",
    "codex-rs/app-server-protocol/src/jsonrpc_lite.rs",
  ]

  private static func makeTranscript(name: String, messages: [Message]) -> Transcript {
    Transcript(
      name: name,
      sourceEvidence: bootstrapSourceEvidence,
      messages: messages
    )
  }

  private static func makeRequest(
    id: Int,
    method: String,
    params: [String: Any]? = nil
  ) -> JSONRPCLine {
    var object: [String: Any] = [
      "id": id,
      "method": method,
    ]
    if let params {
      object["params"] = params
    }
    return makeLine(object: object)
  }

  private static func makeNotification(
    method: String,
    params: [String: Any]? = nil
  ) -> JSONRPCLine {
    var object: [String: Any] = ["method": method]
    if let params {
      object["params"] = params
    }
    return makeLine(object: object)
  }

  private static func makeResponse(id: Int, result: [String: Any]) -> JSONRPCLine {
    makeLine(
      object: [
        "id": id,
        "result": result,
      ]
    )
  }

  private static func makeError(id: Int, code: Int, message: String) -> JSONRPCLine {
    makeLine(
      object: [
        "error": [
          "code": code,
          "message": message,
        ],
        "id": id,
      ]
    )
  }

  private static func makeLine(object: [String: Any]) -> JSONRPCLine {
    do {
      let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
      guard let rawObject = String(data: data, encoding: .utf8) else {
        fatalError("Bootstrap transcript JSON was not valid UTF-8.")
      }
      return try JSONRPCLine(rawObject: rawObject)
    } catch {
      fatalError("Failed to build bootstrap transcript line: \(error)")
    }
  }
}
