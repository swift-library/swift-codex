import Foundation

package final class CodexAppServerProcessDiagnostic: @unchecked Sendable {
  package static let defaultByteLimit = 64 * 1_024

  private let byteLimit: Int
  private let lock = NSLock()
  private var bytes = Data()
  private var omittedByteCount = 0
  private var isDiscardingTruncatedLine = false

  package init(byteLimit: Int = defaultByteLimit) {
    precondition(byteLimit > 0)
    self.byteLimit = byteLimit
  }

  package func append(_ data: Data) {
    guard !data.isEmpty else { return }

    lock.lock()
    defer { lock.unlock() }

    var incoming = data
    if isDiscardingTruncatedLine {
      guard let newlineIndex = incoming.firstIndex(of: 0x0A) else {
        omittedByteCount += incoming.count
        return
      }
      let discardedCount = incoming.distance(
        from: incoming.startIndex,
        to: incoming.index(after: newlineIndex)
      )
      omittedByteCount += discardedCount
      incoming.removeFirst(discardedCount)
      isDiscardingTruncatedLine = false
    }

    bytes.append(incoming)
    if bytes.count > byteLimit {
      let overflowBoundary = bytes.index(
        bytes.startIndex,
        offsetBy: bytes.count - byteLimit
      )
      if let newlineIndex = bytes[overflowBoundary...].firstIndex(of: 0x0A) {
        let discardedCount = bytes.distance(
          from: bytes.startIndex,
          to: bytes.index(after: newlineIndex)
        )
        bytes.removeFirst(discardedCount)
        omittedByteCount += discardedCount
      } else {
        omittedByteCount += bytes.count
        bytes.removeAll(keepingCapacity: true)
        isDiscardingTruncatedLine = true
      }
    }
  }

  package func snapshot() -> String {
    let capturedBytes: Data
    let capturedOmittedByteCount: Int

    lock.lock()
    capturedBytes = bytes
    capturedOmittedByteCount = omittedByteCount
    lock.unlock()

    let decoded = String(decoding: capturedBytes, as: UTF8.self)
    let redacted = Self.redact(decoded)
    guard capturedOmittedByteCount > 0 else { return redacted }

    return "[process output truncated; omitted \(capturedOmittedByteCount) bytes]\n" + redacted
  }

  static func redact(_ text: String) -> String {
    let replacements: [(pattern: String, template: String)] = [
      (
        #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#,
        "Bearer [REDACTED]"
      ),
      (
        #"(?i)\b(?:Cookie|Set-Cookie)\s*:\s*[^\r\n]+"#,
        "Cookie: [REDACTED]"
      ),
      (
        #"(?i)\b((?:api[-_ ]?key|access[-_ ]?token|refresh[-_ ]?token|id[-_ ]?token|session[-_ ]?token|client[-_ ]?secret|secret[-_ ]?access[-_ ]?key|token|secret|password|authorization|cookie)["']?)\s*([:=])\s*("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^\s,;]+)"#,
        "$1$2[REDACTED]"
      ),
      (
        #"\bsk-[A-Za-z0-9_-]{8,}"#,
        "[REDACTED]"
      ),
    ]

    return replacements.reduce(text) { result, replacement in
      result.replacingOccurrences(
        of: replacement.pattern,
        with: replacement.template,
        options: .regularExpression
      )
    }
  }
}
