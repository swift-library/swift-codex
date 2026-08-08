import CodexExec

/// Streamed SDK turn result.
public struct StreamedTurn: Sendable {
  /// Ordered thread events emitted by the underlying exec protocol.
  public let events: AsyncThrowingStream<ThreadEvent, Error>

  /// Creates a streamed turn from an event stream.
  public init(events: AsyncThrowingStream<ThreadEvent, Error>) {
    self.events = events
  }
}

extension StreamedTurn: AsyncSequence {
  /// Event element yielded by the streamed turn.
  public typealias Element = ThreadEvent
  /// Async iterator over streamed turn events.
  public typealias AsyncIterator = AsyncThrowingStream<ThreadEvent, Error>.AsyncIterator

  /// Returns an iterator over the turn event stream.
  public func makeAsyncIterator() -> AsyncIterator {
    events.makeAsyncIterator()
  }
}

/// Buffered SDK turn convenience value produced by aggregating streamed events.
public struct Turn: Equatable, Sendable {
  /// Completed protocol items observed during the turn.
  public var items: [ThreadItem]
  /// Final assistant response selected by SDK aggregation.
  public var finalResponse: String
  /// Usage reported by the terminal turn event, if available.
  public var usage: Usage?

  /// Creates a buffered turn value.
  public init(
    items: [ThreadItem] = [],
    finalResponse: String = "",
    usage: Usage? = nil
  ) {
    self.items = items
    self.finalResponse = finalResponse
    self.usage = usage
  }
}

/// SDK event name backed by the canonical exec protocol event model.
public typealias ThreadEvent = CodexExecEvent
/// SDK item name backed by the canonical exec protocol item model.
public typealias ThreadItem = CodexExecItem
/// SDK usage name backed by the canonical exec protocol usage model.
public typealias Usage = CodexExecUsage
/// SDK error name backed by the canonical exec protocol error model.
public typealias ThreadError = CodexExecThreadError
