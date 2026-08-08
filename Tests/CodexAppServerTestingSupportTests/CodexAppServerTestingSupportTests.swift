import CodexAppServerTestingSupport
import Testing

@Suite("CodexAppServerTestingSupport")
struct CodexAppServerTestingSupportTests {
  @Test("in-memory line peer records outbound lines and replays inbound lines")
  func inMemoryLinePeerRecordsOutboundAndReplaysInboundLines() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    try await peer.sendLine(#"{"method":"initialized"}"#)

    #expect(await peer.nextSentLine() == #"{"method":"initialized"}"#)

    peer.receiveLine(#"{"id":1,"result":{}}"#)
    var iterator = peer.inboundLines.makeAsyncIterator()
    #expect(try await iterator.next() == #"{"id":1,"result":{}}"#)

    peer.finishInbound()
    #expect(try await iterator.next() == nil)
  }

  @Test("bootstrap transcript replay enforces ordered JSON-RPC lines")
  func bootstrapTranscriptReplayEnforcesOrderedLines() throws {
    let transcript = CodexAppServerBootstrapTranscripts.bootstrapSuccess
    var replay = transcript.makeReplay()

    try replay.sendClientLine(transcript.messages[0].line.encoded)
    #expect(try replay.receiveServerLine() == transcript.messages[1].line.encoded)
    try replay.sendClientLine(transcript.messages[2].line.encoded)
    try replay.finish()
  }
}
