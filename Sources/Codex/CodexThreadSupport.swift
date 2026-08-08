import Foundation

package protocol CodexThreadExecuting: Sendable {
  func eventStream(
    for request: CodexThreadExecutionRequest
  ) throws -> AsyncThrowingStream<ThreadEvent, Error>
}

package struct CodexThreadExecutionRequest: Sendable {
  let proposedThreadID: String
  let shouldEmitThreadStarted: Bool
  let input: Input
  let normalizedInput: NormalizedInput
  let context: CodexThreadExecutionContext
}

package struct CodexThreadExecutionContext: Equatable, Sendable {
  let codexPathOverride: URL?
  let baseURL: URL?
  let apiKey: String?
  let config: CodexConfigObject
  let environment: [String: String]?
  let model: String?
  let sandboxMode: String?
  let workingDirectory: URL?
  let skipGitRepoCheck: Bool
  let modelReasoningEffort: String?
  let networkAccessEnabled: Bool?
  let webSearchMode: String?
  let approvalPolicy: String?
  let additionalDirectories: [URL]
  let outputSchema: CodexConfigObject?
}

final class CodexCallerCancellationProbe: @unchecked Sendable {
  private let task: UnsafeCurrentTask?

  init(task: UnsafeCurrentTask?) {
    self.task = task
  }

  var isCancelled: Bool {
    task?.isCancelled == true
  }
}

struct NormalizedInput {
  let prompt: String
  let images: [URL]
}

struct BufferedTurnAccumulator {
  private var items: [ThreadItem] = []
  private var finalResponse = ""
  private var usage: Usage?
  private var turnFailure: ThreadError?
  private var streamFailure: ThreadError?
  private(set) var didComplete = false

  mutating func consume(_ event: ThreadEvent) throws {
    switch event {
    case .threadStarted, .turnStarted, .itemStarted, .itemUpdated, .unknown:
      return

    case .itemCompleted(let item):
      items.append(item)
      if item.kind == .agentMessage, let text = item.text {
        finalResponse = text
      }

    case .turnCompleted(let usageValue):
      usage = usageValue
      didComplete = true

    case .turnFailed(let error):
      turnFailure = error
      throw error

    case .error(let error):
      streamFailure = error
      throw error
    }
  }

  func completedTurn() -> Turn {
    if let turnFailure {
      return Turn(items: items, finalResponse: turnFailure.message, usage: usage)
    }
    if let streamFailure {
      return Turn(items: items, finalResponse: streamFailure.message, usage: usage)
    }
    return Turn(items: items, finalResponse: finalResponse, usage: usage)
  }
}

func mergedObject(
  existing: CodexConfigValue?,
  updates: CodexConfigObject
) -> CodexConfigValue {
  var object: CodexConfigObject

  if case .object(let existingObject) = existing {
    object = existingObject
  } else {
    object = [:]
  }

  for (key, value) in updates {
    object[key] = value
  }

  return .object(object)
}

final class ThreadState: @unchecked Sendable {
  private var id: String?
  private let lock = NSLock()

  init(id: String?) {
    self.id = id
  }

  var currentID: String? {
    withLock { id }
  }

  func prepareIDForTurn() -> (id: String, wasResolvedNow: Bool) {
    withLock {
      if let id {
        return (id, false)
      }

      let resolvedID = UUID().uuidString
      return (resolvedID, true)
    }
  }

  func resolveFromThreadStarted(_ resolvedID: String) {
    withLock {
      if id == nil {
        id = resolvedID
      }
    }
  }

  private func withLock<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}

struct CodexProcessError: Error {
  let message: String
}

func serializedConfigOverrides(
  _ configOverrides: CodexConfigObject
) throws -> [String] {
  var overrides: [String] = []
  try flattenConfigOverrides(
    value: .object(configOverrides),
    prefix: "",
    overrides: &overrides
  )
  return overrides
}

private func flattenConfigOverrides(
  value: CodexConfigValue,
  prefix: String,
  overrides: inout [String]
) throws {
  guard case .object(let object) = value else {
    if prefix.isEmpty {
      throw CodexProcessError(message: "Codex config overrides must be objects")
    }
    overrides.append("\(prefix)=\(try tomlValue(value, path: prefix))")
    return
  }

  if prefix.isEmpty && object.isEmpty {
    return
  }

  if !prefix.isEmpty && object.isEmpty {
    overrides.append("\(prefix)={}")
    return
  }

  for (key, child) in object {
    let path = prefix.isEmpty ? key : "\(prefix).\(key)"
    if case .object = child {
      try flattenConfigOverrides(value: child, prefix: path, overrides: &overrides)
    } else {
      overrides.append("\(path)=\(try tomlValue(child, path: path))")
    }
  }
}

func tomlValue(_ value: CodexConfigValue, path: String) throws -> String {
  switch value {
  case .null:
    throw CodexProcessError(message: "Codex config override at \(path) cannot be null")
  case .bool(let value):
    return value ? "true" : "false"
  case .number(let value):
    guard value.isFinite else {
      throw CodexProcessError(
        message: "Codex config override at \(path) must be a finite number"
      )
    }
    return "\(value)"
  case .string(let value):
    return value.debugDescription
  case .array(let values):
    let rendered = try values.enumerated().map { index, child in
      try tomlValue(child, path: "\(path)[\(index)]")
    }
    return "[\(rendered.joined(separator: ", "))]"
  case .object(let values):
    let rendered = try values.map { key, child in
      "\(formatTOMLKey(key)) = \(try tomlValue(child, path: "\(path).\(key)"))"
    }
    return "{\(rendered.joined(separator: ", "))}"
  }
}

private func formatTOMLKey(_ key: String) -> String {
  let bareKey = try? NSRegularExpression(pattern: #"^[A-Za-z0-9_-]+$"#)
  let fullRange = NSRange(location: 0, length: key.utf16.count)
  if bareKey?.firstMatch(in: key, range: fullRange) != nil {
    return key
  }
  return key.debugDescription
}
