import Foundation
import Testing

@testable import CodexMCP

@Suite("CodexMCP Client Basic Operations", .serialized)
struct CodexMCPClientBasicOperationTests {
  @Test("Lifecycle shell ping sends ping and succeeds without changing running state")
  func pingSucceedsWithoutChangingRunningState() async throws {
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let transcript = HandshakeTranscript()

    let serverTask = Task {
      try await performStartupHandshake(stdinPipe: stdinPipe, stdoutPipe: stdoutPipe)
      let pingLine = try await readLine(from: stdinPipe.fileHandleForReading.fileDescriptor)
      await transcript.record(pingLine)

      stdoutPipe.fileHandleForWriting.write(
        Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n".utf8)
      )
    }

    let client = CodexMCPClient(
      clientInfo: testMCPClientInfo,
      subprocessLauncher: .init { _ in
        CodexMCPManagedSubprocess(
          standardInput: stdinPipe,
          standardOutput: stdoutPipe,
          standardError: Pipe(),
        ) {}
      },
    )

    try await client.start()
    try await client.ping()
    try await serverTask.value

    let pingPayload = try parseJSONObject(from: await transcript.lines[0])
    let state = await client.state

    #expect(pingPayload["jsonrpc"] as? String == "2.0")
    #expect(pingPayload["method"] as? String == "ping")
    #expect((pingPayload["id"] as? NSNumber)?.intValue == 1)
    #expect(isAbsentOrEmptyObject(pingPayload["params"]))
    #expect(state == .running)
  }

  @Test("Lifecycle shell maps ping JSON-RPC error response to the CodexMCP error surface")
  func pingJSONRPCErrorUsesCodexMCPErrorSurface() async throws {
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()

    let serverTask = Task {
      try await performStartupHandshake(stdinPipe: stdinPipe, stdoutPipe: stdoutPipe)
      _ = try await readLine(from: stdinPipe.fileHandleForReading.fileDescriptor)
      stdoutPipe.fileHandleForWriting.write(
        Data(
          "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"method not found\",\"data\":{\"retryable\":false}}}\n"
            .utf8)
      )
    }

    let client = CodexMCPClient(
      clientInfo: testMCPClientInfo,
      subprocessLauncher: .init { _ in
        CodexMCPManagedSubprocess(
          standardInput: stdinPipe,
          standardOutput: stdoutPipe,
          standardError: Pipe(),
        ) {}
      },
    )

    try await client.start()

    await #expect(
      throws: CodexMCPError.jsonrpcFailure(
        .init(
          code: -32601,
          message: "method not found",
          data: .object(["retryable": .bool(false)])
        ))
    ) {
      try await client.ping()
    }

    try await serverTask.value

    let state = await client.state
    #expect(state == .running)
  }

  @Test("Public JSON values preserve Int64 integers separately from floating point")
  func publicJSONValuesPreserveNumberKinds() throws {
    let data = Data(#"{"integer":9223372036854775807,"double":1.25}"#.utf8)
    let decoded = try JSONDecoder().decode(CodexMCPJSONValue.self, from: data)
    #expect(
      decoded
        == .object([
          "integer": .integer(Int64.max),
          "double": .double(1.25),
        ]))

    let encoded = try JSONEncoder().encode(decoded)
    let roundTrip = try JSONDecoder().decode(CodexMCPJSONValue.self, from: encoded)
    #expect(roundTrip == decoded)
    #expect(requestID(from: .double(1.0)) == nil)
  }

  @Test("Lifecycle shell maps unmatched ping responses to protocol failure")
  func unmatchedPingResponseUsesProtocolFailure() async throws {
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()

    let serverTask = Task {
      try await performStartupHandshake(stdinPipe: stdinPipe, stdoutPipe: stdoutPipe)
      _ = try await readLine(from: stdinPipe.fileHandleForReading.fileDescriptor)
      stdoutPipe.fileHandleForWriting.write(
        Data(makePingSuccessResponseLine(requestID: 999).utf8)
      )
      stdoutPipe.fileHandleForWriting.write(Data("\n".utf8))
    }

    let client = CodexMCPClient(
      clientInfo: testMCPClientInfo,
      subprocessLauncher: .init { _ in
        CodexMCPManagedSubprocess(
          standardInput: stdinPipe,
          standardOutput: stdoutPipe,
          standardError: Pipe(),
        ) {}
      },
    )

    try await client.start()

    await #expect(throws: CodexMCPError.protocolFailure) {
      try await client.ping()
    }

    try await serverTask.value
  }

  @Test("Lifecycle shell rejects ping before startup")
  func pingFailsOutsideRunningState() async throws {
    let client = CodexMCPClient(clientInfo: testMCPClientInfo)

    await #expect(throws: CodexMCPError.invalidStateTransition(operation: .ping, from: .idle)) {
      try await client.ping()
    }
  }

  @Test(
    "Lifecycle shell listTools preserves the current upstream tool surface without changing running state"
  )
  func listToolsPreservesCurrentUpstreamToolSurface() async throws {
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let transcript = HandshakeTranscript()

    let serverTask = Task {
      try await performStartupHandshake(stdinPipe: stdinPipe, stdoutPipe: stdoutPipe)
      let listToolsLine = try await readLine(from: stdinPipe.fileHandleForReading.fileDescriptor)
      await transcript.record(listToolsLine)

      stdoutPipe.fileHandleForWriting.write(
        Data(makeListToolsResponseLine(requestID: 1).utf8)
      )
      stdoutPipe.fileHandleForWriting.write(Data("\n".utf8))
    }

    let client = CodexMCPClient(
      clientInfo: testMCPClientInfo,
      subprocessLauncher: .init { _ in
        CodexMCPManagedSubprocess(
          standardInput: stdinPipe,
          standardOutput: stdoutPipe,
          standardError: Pipe(),
        ) {}
      },
    )

    try await client.start()
    let tools = try await client.listTools()
    try await serverTask.value

    let listToolsPayload = try parseJSONObject(from: await transcript.lines[0])
    let state = await client.state

    #expect(listToolsPayload["jsonrpc"] as? String == "2.0")
    #expect(listToolsPayload["method"] as? String == "tools/list")
    #expect((listToolsPayload["id"] as? NSNumber)?.intValue == 1)
    #expect(isAbsentOrEmptyObject(listToolsPayload["params"]))
    #expect(tools == makeExpectedToolDescriptors())
    #expect(state == .running)
  }

  @Test("Lifecycle shell maps listTools JSON-RPC error response to the CodexMCP error surface")
  func listToolsJSONRPCErrorUsesCodexMCPErrorSurface() async throws {
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()

    let serverTask = Task {
      try await performStartupHandshake(stdinPipe: stdinPipe, stdoutPipe: stdoutPipe)
      _ = try await readLine(from: stdinPipe.fileHandleForReading.fileDescriptor)
      stdoutPipe.fileHandleForWriting.write(
        Data(
          "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"method not found\"}}\n"
            .utf8)
      )
    }

    let client = CodexMCPClient(
      clientInfo: testMCPClientInfo,
      subprocessLauncher: .init { _ in
        CodexMCPManagedSubprocess(
          standardInput: stdinPipe,
          standardOutput: stdoutPipe,
          standardError: Pipe(),
        ) {}
      },
    )

    try await client.start()

    await #expect(
      throws: CodexMCPError.jsonrpcFailure(
        .init(code: -32601, message: "method not found"))
    ) {
      try await client.listTools()
    }

    try await serverTask.value

    let state = await client.state
    #expect(state == .running)
  }

  @Test("Lifecycle shell routes concurrent client initiated responses by request id")
  func clientInitiatedResponsesAreRoutedByRequestID() async throws {
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let transcript = HandshakeTranscript()

    let client = CodexMCPClient(
      clientInfo: testMCPClientInfo,
      subprocessLauncher: .init { _ in
        CodexMCPManagedSubprocess(
          standardInput: stdinPipe,
          standardOutput: stdoutPipe,
          standardError: Pipe(),
        ) {}
      },
    )

    try await startClient(client, stdinPipe: stdinPipe, stdoutPipe: stdoutPipe)

    let pingTask = Task {
      try await client.ping()
    }

    let listToolsTask = Task {
      try await client.listTools()
    }

    let firstLine = try await readLine(from: stdinPipe.fileHandleForReading.fileDescriptor)
    await transcript.record(firstLine)
    let secondLine = try await readLine(from: stdinPipe.fileHandleForReading.fileDescriptor)
    await transcript.record(secondLine)

    let firstPayload = try parseJSONObject(from: firstLine)
    let secondPayload = try parseJSONObject(from: secondLine)
    let pingRequestID = try requestID(forMethod: "ping", from: [firstPayload, secondPayload])
    let listToolsRequestID = try requestID(
      forMethod: "tools/list", from: [firstPayload, secondPayload])

    stdoutPipe.fileHandleForWriting.write(
      Data(makeListToolsResponseLine(requestID: listToolsRequestID).utf8)
    )
    stdoutPipe.fileHandleForWriting.write(Data("\n".utf8))
    let tools = try await listToolsTask.value
    stdoutPipe.fileHandleForWriting.write(
      Data(makePingSuccessResponseLine(requestID: pingRequestID).utf8)
    )
    stdoutPipe.fileHandleForWriting.write(Data("\n".utf8))
    try await pingTask.value
    let lines = await transcript.lines

    #expect(lines.count == 2)
    #expect(
      Set([firstPayload["method"] as? String, secondPayload["method"] as? String])
        == Set(["ping", "tools/list"]))
    #expect(tools == makeExpectedToolDescriptors())
  }

  @Test("Lifecycle shell maps malformed listTools response to protocol failure")
  func malformedListToolsResponseUsesProtocolFailure() async throws {
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()

    let serverTask = Task {
      try await performStartupHandshake(stdinPipe: stdinPipe, stdoutPipe: stdoutPipe)
      _ = try await readLine(from: stdinPipe.fileHandleForReading.fileDescriptor)
      stdoutPipe.fileHandleForWriting.write(
        Data(
          "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[{\"name\":\"codex\",\"inputSchema\":\"not-an-object\"}]}}\n"
            .utf8)
      )
    }

    let client = CodexMCPClient(
      clientInfo: testMCPClientInfo,
      subprocessLauncher: .init { _ in
        CodexMCPManagedSubprocess(
          standardInput: stdinPipe,
          standardOutput: stdoutPipe,
          standardError: Pipe(),
        ) {}
      },
    )

    try await client.start()

    await #expect(throws: CodexMCPError.protocolFailure) {
      try await client.listTools()
    }

    try await serverTask.value

    let state = await client.state
    #expect(state == .running)
  }

  @Test("Lifecycle shell rejects listTools before startup")
  func listToolsFailsOutsideRunningState() async throws {
    let client = CodexMCPClient(clientInfo: testMCPClientInfo)

    await #expect(throws: CodexMCPError.invalidStateTransition(operation: .listTools, from: .idle))
    {
      try await client.listTools()
    }
  }

}
