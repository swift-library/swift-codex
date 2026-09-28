import Foundation

/// Native completion also serves synchronous probes without requiring a free
/// Swift cooperative worker to settle an initializer blocked on its result.
final class CodexProcessCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private let completed = DispatchGroup()
  private var result: Result<CodexProcessExit, Error>?
  private var waiters: [CheckedContinuation<CodexProcessExit, Error>] = []

  init() { completed.enter() }

  func wait() async throws -> CodexProcessExit {
    try await withCheckedThrowingContinuation { continuation in
      let value: Result<CodexProcessExit, Error>? = lock.withLock {
        if let result = self.result { return result }
        waiters.append(continuation)
        return nil
      }
      if let value { continuation.resume(with: value) }
    }
  }

  func wait(until deadline: DispatchTime) throws -> CodexProcessExit? {
    guard completed.wait(timeout: deadline) == .success else { return nil }
    return try lock.withLock { try result!.get() }
  }

  func finish(_ result: Result<CodexProcessExit, Error>) {
    let pending: [CheckedContinuation<CodexProcessExit, Error>]? = lock.withLock {
      guard self.result == nil else { return nil }
      self.result = result
      let pending = waiters
      waiters.removeAll()
      return pending
    }
    guard let pending else { return }
    completed.leave()
    for waiter in pending { waiter.resume(with: result) }
  }
}
