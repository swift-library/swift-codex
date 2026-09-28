import Testing

@testable import CodexAppServerRuntime

@Suite("App Server correlation ownership")
struct CodexAppServerCorrelationBudgetTests {
  typealias ID = CodexAppServerConnectionFoundation.RequestID
  private let overflow = CodexAppServerConnectionFoundation.FoundationError.bufferLimitExceeded(
    maximumMessages: 256, maximumBytes: 16 * 1_024 * 1_024)

  @Test("A cancelled ID remains reserved until its late reply is consumed")
  func cancelledIDReservation() async throws {
    let state = CodexAppServerConnectionState()
    let id = ID.string("reusable")
    try await state.addPending(id: id, pendingResponse: .init())
    await state.cancelPending(id: id, error: CancellationError())
    await #expect(throws: CodexAppServerConnectionStateError.duplicatePendingResponse(id: id)) {
      try await state.addPending(id: id, pendingResponse: .init())
    }
    #expect(await state.consumeCancelledResponse(id: id))
    try await state.addPending(id: id, pendingResponse: .init())
    #expect(await state.takePending(id: id) != nil)
    #expect(await state.takePending(id: id) == nil)
  }

  @Test("Client and server admission have independent bounded counts without evicting owners")
  func directionalCountBudgets() async throws {
    let state = CodexAppServerConnectionState()
    for id in 0..<256 {
      try await state.addServerRequest(id: .integer(Int64(id)))
    }
    // A full callback set must leave capacity for client control requests.
    for id in 0..<256 {
      try await state.addPending(id: .integer(Int64(id)), pendingResponse: .init())
    }
    await state.cancelPending(id: .integer(0), error: CancellationError())
    await #expect(throws: overflow) {
      try await state.addPending(id: .integer(256), pendingResponse: .init())
    }
    await #expect(throws: overflow) { try await state.addServerRequest(id: .integer(256)) }
    #expect(await state.consumeCancelledResponse(id: .integer(0)))
    try await state.addPending(id: .integer(257), pendingResponse: .init())
    // Freeing the client slot does not widen server admission.
    await #expect(throws: overflow) { try await state.addServerRequest(id: .integer(256)) }
    try await state.completeServerRequest(id: .integer(0))
    try await state.addServerRequest(id: .integer(257))
    let pending = await state.close()
    #expect(pending?.count == 256)
    #expect(await state.close() == nil)
    #expect(!(await state.consumeCancelledResponse(id: .integer(0))))
  }

  @Test("String ID bytes also bound retained correlation state")
  func identifierByteBudget() async throws {
    let state = CodexAppServerConnectionState()
    let id = ID.string(String(repeating: "x", count: 16 * 1_024 * 1_024))
    try await state.addServerRequest(id: id)
    await #expect(throws: overflow) {
      try await state.addPending(id: .integer(1), pendingResponse: .init())
    }
    try await state.completeServerRequest(id: id)
    try await state.addPending(id: .integer(1), pendingResponse: .init())
    await state.removePending(id: .integer(1))
    try await state.addServerRequest(id: id)
    try await state.completeServerRequest(id: id)
  }
}
