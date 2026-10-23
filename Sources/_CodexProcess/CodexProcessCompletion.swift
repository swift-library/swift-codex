import Foundation

/// The lock serializes completion and deadline expiry; each waiter is removed once.
final class CodexProcessCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<CodexProcessExit, Error>?
  private var waiters: [UUID: CheckedContinuation<CodexProcessExit?, Error>] = [:]

  func wait() async throws -> CodexProcessExit {
    try await wait(until: .distantFuture)!
  }

  func wait(until deadline: DispatchTime) async throws -> CodexProcessExit? {
    let id = UUID()
    return try await withCheckedThrowingContinuation { continuation in
      let value: Result<CodexProcessExit, Error>? = lock.withLock {
        if let result { return result }
        waiters[id] = continuation
        return nil
      }
      if let value {
        continuation.resume(with: value.map(Optional.some))
      } else if deadline != .distantFuture {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) { [weak self] in
          guard let self else { return }
          let waiter = self.lock.withLock { self.waiters.removeValue(forKey: id) }
          waiter?.resume(returning: nil)
        }
      }
    }
  }

  func finish(_ result: Result<CodexProcessExit, Error>) {
    let pending: [CheckedContinuation<CodexProcessExit?, Error>] = lock.withLock {
      guard self.result == nil else { return [] }
      self.result = result
      let pending = Array(waiters.values)
      waiters.removeAll()
      return pending
    }
    for waiter in pending { waiter.resume(with: result.map(Optional.some)) }
  }
}
