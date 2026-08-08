import CodexAppServerTestingSupport
import Foundation
import Testing

@testable import CodexAppServerClient
@testable import CodexAppServerProtocol
@testable import CodexAppServerRuntime
@testable import CodexAppServerStdio

private typealias Stable = CodexAppServerProtocol.Stable
private typealias Experimental = CodexAppServerProtocol.Experimental

@Suite("CodexAppServer Realtime Binding")
struct CodexAppServerRealtimeBindingTests {
  @Test("Realtime binding sends experimental start append and stop requests")
  func realtimeBindingSendsExperimentalStartAppendAndStopRequests() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startRealtimeReadyConnection(peer: peer)

    let startTask = Task {
      try await connection.threadRealtimeStart(
        .init(
          outputModality: .audio,
          prompt: "Speak briefly",
          realtimeSessionId: "session-1",
          threadId: "thread-1",
          transport: .webrtc(.init(sdp: "offer-sdp", type: .webrtc)),
          voice: .alloy
        ))
    }
    guard case .threadRealtimeStartRequest(let start) = try await nextRealtimeRequest(peer) else {
      Issue.record("Expected thread/realtime/start generated experimental request.")
      return
    }
    #expect(start.method == .threadRealtimeStart)
    #expect(start.params.outputModality == .audio)
    #expect(start.params.prompt == "Speak briefly")
    #expect(start.params.threadId == "thread-1")
    let startResponse: Experimental.ThreadRealtimeStartResponse = [
      "accepted": Experimental.JSONValue.bool(true)
    ]
    peer.receiveLine(
      try responseLine(
        id: start.id,
        result: startResponse
      ))
    #expect(try await startTask.value["accepted"] == Experimental.JSONValue.bool(true))

    let appendAudioTask = Task {
      try await connection.threadRealtimeAppendAudio(
        .init(
          audio: .init(
            data: "AAAA",
            itemId: "item-1",
            numChannels: 1,
            sampleRate: 24_000,
            samplesPerChannel: 2
          ),
          threadId: "thread-1"
        ))
    }
    guard
      case .threadRealtimeAppendAudioRequest(let appendAudio) =
        try await nextRealtimeRequest(peer)
    else {
      Issue.record("Expected thread/realtime/appendAudio generated experimental request.")
      return
    }
    #expect(appendAudio.method == .threadRealtimeAppendAudio)
    #expect(appendAudio.params.audio.data == "AAAA")
    #expect(appendAudio.params.threadId == "thread-1")
    let appendAudioResponse: Experimental.ThreadRealtimeAppendAudioResponse = [
      "queued": .bool(true)
    ]
    peer.receiveLine(
      try responseLine(
        id: appendAudio.id,
        result: appendAudioResponse
      ))
    #expect(try await appendAudioTask.value["queued"] == .bool(true))

    let appendTextTask = Task {
      try await connection.threadRealtimeAppendText(
        .init(
          text: "hello",
          threadId: "thread-1"
        ))
    }
    guard
      case .threadRealtimeAppendTextRequest(let appendText) =
        try await nextRealtimeRequest(peer)
    else {
      Issue.record("Expected thread/realtime/appendText generated experimental request.")
      return
    }
    #expect(appendText.method == .threadRealtimeAppendText)
    #expect(appendText.params.text == "hello")
    let appendTextResponse: Experimental.ThreadRealtimeAppendTextResponse = ["queued": .bool(true)]
    peer.receiveLine(
      try responseLine(
        id: appendText.id,
        result: appendTextResponse
      ))
    #expect(try await appendTextTask.value["queued"] == .bool(true))

    let stopTask = Task {
      try await connection.threadRealtimeStop(.init(threadId: "thread-1"))
    }
    guard case .threadRealtimeStopRequest(let stop) = try await nextRealtimeRequest(peer) else {
      Issue.record("Expected thread/realtime/stop generated experimental request.")
      return
    }
    #expect(stop.method == .threadRealtimeStop)
    #expect(stop.params.threadId == "thread-1")
    let stopResponse: Experimental.ThreadRealtimeStopResponse = ["stopped": .bool(true)]
    peer.receiveLine(
      try responseLine(
        id: stop.id,
        result: stopResponse
      ))
    #expect(try await stopTask.value["stopped"] == .bool(true))

    await connection.close()
  }

  @Test("Realtime binding sends experimental list voices request")
  func realtimeBindingSendsExperimentalListVoicesRequest() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startRealtimeReadyConnection(peer: peer)

    let voicesTask = Task {
      try await connection.threadRealtimeListVoices()
    }
    guard
      case .threadRealtimeListVoicesRequest(let voices) =
        try await nextRealtimeRequest(peer)
    else {
      Issue.record("Expected thread/realtime/listVoices generated experimental request.")
      return
    }
    #expect(voices.method == .threadRealtimeListVoices)
    #expect(voices.params.isEmpty)
    peer.receiveLine(
      try responseLine(
        id: voices.id,
        result: Experimental.ThreadRealtimeListVoicesResponse(
          voices: .init(
            defaultV1: .alloy,
            defaultV2: .marin,
            v1: [.alloy, .echo],
            v2: [.marin, .verse]
          )
        )
      ))
    let response = try await voicesTask.value
    #expect(response.voices.defaultV1 == .alloy)
    #expect(response.voices.v2 == [.marin, .verse])

    await connection.close()
  }

  @Test("Realtime events arrive on the notification stream")
  func realtimeEventsArriveOnNotificationStream() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startRealtimeReadyConnection(peer: peer)
    var rawNotifications = connection.notifications.makeAsyncIterator()

    peer.receiveLine(try realtimeStartedNotificationLine())
    guard
      case .threadRealtimeStartedNotification(let rawStarted) =
        try await rawNotifications.next()
    else {
      Issue.record("Expected raw thread/realtime/started notification.")
      return
    }
    #expect(rawStarted.params.threadId == "thread-1")
    #expect(rawStarted.params.version == .v2)

    peer.receiveLine(try realtimeItemAddedNotificationLine())
    guard
      case .threadRealtimeItemAddedNotification(let rawItemAdded) =
        try await rawNotifications.next()
    else {
      Issue.record("Expected raw thread/realtime/itemAdded notification.")
      return
    }
    #expect(rawItemAdded.params.threadId == "thread-1")
    #expect(rawItemAdded.params.item == .object(["id": .string("item-1")]))

    peer.receiveLine(try realtimeTranscriptDeltaNotificationLine())
    guard
      case .threadRealtimeTranscriptDeltaNotification(let rawTranscriptDelta) =
        try await rawNotifications.next()
    else {
      Issue.record("Expected raw thread/realtime/transcript/delta notification.")
      return
    }
    #expect(rawTranscriptDelta.params.delta == "hel")
    #expect(rawTranscriptDelta.params.role == "assistant")

    peer.receiveLine(try realtimeTranscriptDoneNotificationLine())
    guard
      case .threadRealtimeTranscriptDoneNotification(let rawTranscriptDone) =
        try await rawNotifications.next()
    else {
      Issue.record("Expected raw thread/realtime/transcript/done notification.")
      return
    }
    #expect(rawTranscriptDone.params.text == "hello")
    #expect(rawTranscriptDone.params.threadId == "thread-1")

    peer.receiveLine(try realtimeOutputAudioDeltaNotificationLine())
    guard
      case .threadRealtimeOutputAudioDeltaNotification(let rawAudioDelta) =
        try await rawNotifications.next()
    else {
      Issue.record("Expected raw thread/realtime/outputAudio/delta notification.")
      return
    }
    #expect(rawAudioDelta.params.audio.data == "AAAA")
    #expect(rawAudioDelta.params.audio.sampleRate == 24_000)

    peer.receiveLine(try realtimeSdpNotificationLine())
    guard case .threadRealtimeSdpNotification(let rawSdp) = try await rawNotifications.next() else {
      Issue.record("Expected raw thread/realtime/sdp notification.")
      return
    }
    #expect(rawSdp.params.sdp == "answer-sdp")
    #expect(rawSdp.params.threadId == "thread-1")

    peer.receiveLine(try realtimeErrorNotificationLine())
    guard case .threadRealtimeErrorNotification(let rawError) = try await rawNotifications.next()
    else {
      Issue.record("Expected raw thread/realtime/error notification.")
      return
    }
    #expect(rawError.params.message == "temporary failure")
    #expect(rawError.params.threadId == "thread-1")

    peer.receiveLine(try realtimeClosedNotificationLine())
    guard case .threadRealtimeClosedNotification(let rawClosed) = try await rawNotifications.next()
    else {
      Issue.record("Expected raw thread/realtime/closed notification.")
      return
    }
    #expect(rawClosed.params.reason == "client-stop")
    #expect(rawClosed.params.threadId == "thread-1")

    await connection.close()
  }

  @Test("Realtime pending request fails when connection closes")
  func realtimePendingRequestFailsWhenConnectionCloses() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startRealtimeReadyConnection(peer: peer)

    let requestTask = Task {
      try await connection.threadRealtimeAppendText(
        .init(
          text: "slow",
          threadId: "thread-close"
        ))
    }

    guard
      case .threadRealtimeAppendTextRequest(let request) =
        try await nextRealtimeRequest(peer)
    else {
      Issue.record("Expected thread/realtime/appendText generated experimental request.")
      return
    }
    #expect(request.params.threadId == "thread-close")

    await connection.close()

    do {
      _ = try await requestTask.value
      Issue.record("Expected close failure.")
    } catch let error as CodexAppServerClientError {
      #expect(error == .closed)
    }
  }

}
private func startRealtimeReadyConnection(
  peer: CodexAppServerInMemoryLinePeer
) async throws -> CodexAppServerConnection {
  let startTask = Task {
    try await makeRealtimeClient(peer: peer).start()
  }

  let initializeLine = await peer.nextSentLine()
  let initializeRequest = try CodexAppServerProtocolContractSupport.Initialize
    .decodeInitializeRequest(from: initializeLine)
  #expect(initializeRequest.params.capabilities?.experimentalApi == true)
  peer.receiveLine(try initializeResponseLine(id: initializeRequest.id))

  let initializedLine = await peer.nextSentLine()
  _ = try CodexAppServerProtocolContractSupport.Initialize
    .decodeInitializedNotification(from: initializedLine)

  return try await startTask.value
}

private func makeRealtimeClient(peer: CodexAppServerInMemoryLinePeer) -> CodexAppServerClient {
  CodexAppServerClient(
    sessionConfiguration: .init(
      clientInfo: .init(
        name: "swift_codex_realtime_tests",
        title: "swift-codex Realtime Tests",
        version: "0.1.0"
      ),
      experimentalApi: true
    ),
    transportFactory: {
      peer
    }
  )
}

private func nextRealtimeRequest(
  _ peer: CodexAppServerInMemoryLinePeer
) async throws -> Experimental.ClientRequest {
  try decode(Experimental.ClientRequest.self, from: await peer.nextSentLine())
}

private func initializeResponseLine(id: Stable.RequestId) throws -> String {
  try CodexAppServerProtocolContractSupport.Initialize.encodeInitializeResponseLine(
    id: id,
    response: .init(
      codexHome: "/tmp/swift-codex/codex-home",
      platformFamily: "unix",
      platformOs: "macos",
      userAgent: "Codex/swift-codex-realtime-fixture"
    )
  )
}

private func responseLine<T: Encodable>(
  id: Experimental.RequestId,
  result: T
) throws -> String {
  try CodexAppServerConnectionFoundation.encodeLine(
    Stable.JSONRPCResponse(id: stableRequestID(id), result: try Stable.JSONValue(result))
  )
}

private func realtimeStartedNotificationLine() throws -> String {
  try CodexAppServerConnectionFoundation.encodeLine(
    Stable.ServerNotification.threadRealtimeStartedNotification(
      .init(
        method: .threadRealtimeStarted,
        params: .init(realtimeSessionId: "session-1", threadId: "thread-1", version: .v2)
      ))
  )
}

private func realtimeItemAddedNotificationLine() throws -> String {
  try CodexAppServerConnectionFoundation.encodeLine(
    Stable.ServerNotification.threadRealtimeItemAddedNotification(
      .init(
        method: .threadRealtimeItemAdded,
        params: .init(item: .object(["id": .string("item-1")]), threadId: "thread-1")
      ))
  )
}

private func realtimeTranscriptDeltaNotificationLine() throws -> String {
  try CodexAppServerConnectionFoundation.encodeLine(
    Stable.ServerNotification.threadRealtimeTranscriptDeltaNotification(
      .init(
        method: .threadRealtimeTranscriptDelta,
        params: .init(delta: "hel", role: "assistant", threadId: "thread-1")
      ))
  )
}

private func realtimeTranscriptDoneNotificationLine() throws -> String {
  try CodexAppServerConnectionFoundation.encodeLine(
    Stable.ServerNotification.threadRealtimeTranscriptDoneNotification(
      .init(
        method: .threadRealtimeTranscriptDone,
        params: .init(role: "assistant", text: "hello", threadId: "thread-1")
      ))
  )
}

private func realtimeOutputAudioDeltaNotificationLine() throws -> String {
  try CodexAppServerConnectionFoundation.encodeLine(
    Stable.ServerNotification.threadRealtimeOutputAudioDeltaNotification(
      .init(
        method: .threadRealtimeOutputAudioDelta,
        params: .init(
          audio: .init(
            data: "AAAA",
            itemId: "item-1",
            numChannels: 1,
            sampleRate: 24_000,
            samplesPerChannel: 2
          ),
          threadId: "thread-1"
        )
      ))
  )
}

private func realtimeSdpNotificationLine() throws -> String {
  try CodexAppServerConnectionFoundation.encodeLine(
    Stable.ServerNotification.threadRealtimeSdpNotification(
      .init(
        method: .threadRealtimeSdp,
        params: .init(sdp: "answer-sdp", threadId: "thread-1")
      ))
  )
}

private func realtimeErrorNotificationLine() throws -> String {
  try CodexAppServerConnectionFoundation.encodeLine(
    Stable.ServerNotification.threadRealtimeErrorNotification(
      .init(
        method: .threadRealtimeError,
        params: .init(message: "temporary failure", threadId: "thread-1")
      ))
  )
}

private func realtimeClosedNotificationLine() throws -> String {
  try CodexAppServerConnectionFoundation.encodeLine(
    Stable.ServerNotification.threadRealtimeClosedNotification(
      .init(
        method: .threadRealtimeClosed,
        params: .init(reason: "client-stop", threadId: "thread-1")
      ))
  )
}

private func stableRequestID(_ requestID: Experimental.RequestId) -> Stable.RequestId {
  switch requestID {
  case .requestidoption1(let value):
    return .requestidoption1(value)
  case .requestidoption2(let value):
    return .requestidoption2(value)
  }
}

private func decode<T: Decodable>(_ type: T.Type, from line: String) throws -> T {
  try JSONDecoder().decode(type, from: Data(line.utf8))
}
