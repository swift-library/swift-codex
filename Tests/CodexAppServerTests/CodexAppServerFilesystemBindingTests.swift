import CodexAppServerTestingSupport
import Foundation
import Testing

@testable import CodexAppServerClient
@testable import CodexAppServerProtocol
@testable import CodexAppServerRuntime
@testable import CodexAppServerStdio

private typealias Stable = CodexAppServerProtocol.Stable

@Suite("CodexAppServer Filesystem Binding")
struct CodexAppServerFilesystemBindingTests {
  @Test("Filesystem binding sends stable read and metadata requests")
  func filesystemBindingSendsStableReadAndMetadataRequests() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startFilesystemReadyConnection(peer: peer)

    let readFileTask = Task {
      try await connection.fsReadFile(.init(path: "/tmp/swift-codex/project/README.md"))
    }
    guard case .fsReadFileRequest(let readFile) = try await nextRequest(peer) else {
      Issue.record("Expected fs/readFile generated request.")
      return
    }
    #expect(readFile.method == .fsReadFile)
    #expect(readFile.params.path == "/tmp/swift-codex/project/README.md")
    peer.receiveLine(
      try responseLine(
        id: readFile.id,
        result: Stable.FsReadFileResponse(dataBase64: "aGVsbG8=")
      ))
    #expect(try await readFileTask.value.dataBase64 == "aGVsbG8=")

    let metadataTask = Task {
      try await connection.fsGetMetadata(.init(path: "/tmp/swift-codex/project/README.md"))
    }
    guard case .fsGetMetadataRequest(let metadata) = try await nextRequest(peer) else {
      Issue.record("Expected fs/getMetadata generated request.")
      return
    }
    #expect(metadata.method == .fsGetMetadata)
    peer.receiveLine(
      try responseLine(
        id: metadata.id,
        result: Stable.FsGetMetadataResponse(
          createdAtMs: 1_730_910_000,
          isDirectory: false,
          isFile: true,
          isSymlink: false,
          modifiedAtMs: 1_730_920_000
        )
      ))
    let metadataResponse = try await metadataTask.value
    #expect(metadataResponse.isFile)
    #expect(!metadataResponse.isDirectory)

    let readDirectoryTask = Task {
      try await connection.fsReadDirectory(.init(path: "/tmp/swift-codex/project"))
    }
    guard case .fsReadDirectoryRequest(let readDirectory) = try await nextRequest(peer) else {
      Issue.record("Expected fs/readDirectory generated request.")
      return
    }
    #expect(readDirectory.method == .fsReadDirectory)
    peer.receiveLine(
      try responseLine(
        id: readDirectory.id,
        result: Stable.FsReadDirectoryResponse(entries: [
          .init(fileName: "Sources", isDirectory: true, isFile: false),
          .init(fileName: "Package.swift", isDirectory: false, isFile: true),
        ])
      ))
    let directoryResponse = try await readDirectoryTask.value
    #expect(directoryResponse.entries.map(\.fileName) == ["Sources", "Package.swift"])

    await connection.close()
  }

  @Test("Filesystem binding sends stable mutation and watch requests")
  func filesystemBindingSendsStableMutationAndWatchRequests() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startFilesystemReadyConnection(peer: peer)

    let writeTask = Task {
      try await connection.fsWriteFile(
        .init(
          dataBase64: "cGF5bG9hZA==",
          path: "/tmp/swift-codex/project/file.txt"
        ))
    }
    guard case .fsWriteFileRequest(let write) = try await nextRequest(peer) else {
      Issue.record("Expected fs/writeFile generated request.")
      return
    }
    #expect(write.method == .fsWriteFile)
    #expect(write.params.dataBase64 == "cGF5bG9hZA==")
    peer.receiveLine(try responseLine(id: write.id, result: Stable.FsWriteFileResponse()))
    #expect(try await writeTask.value.isEmpty)

    let mkdirTask = Task {
      try await connection.fsCreateDirectory(
        .init(
          path: "/tmp/swift-codex/project/new",
          recursive: true
        ))
    }
    guard case .fsCreateDirectoryRequest(let mkdir) = try await nextRequest(peer) else {
      Issue.record("Expected fs/createDirectory generated request.")
      return
    }
    #expect(mkdir.method == .fsCreateDirectory)
    #expect(mkdir.params.recursive == true)
    peer.receiveLine(try responseLine(id: mkdir.id, result: Stable.FsCreateDirectoryResponse()))
    #expect(try await mkdirTask.value.isEmpty)

    let copyTask = Task {
      try await connection.fsCopy(
        .init(
          destinationPath: "/tmp/swift-codex/project/copy.txt",
          recursive: false,
          sourcePath: "/tmp/swift-codex/project/file.txt"
        ))
    }
    guard case .fsCopyRequest(let copy) = try await nextRequest(peer) else {
      Issue.record("Expected fs/copy generated request.")
      return
    }
    #expect(copy.method == .fsCopy)
    #expect(copy.params.destinationPath == "/tmp/swift-codex/project/copy.txt")
    peer.receiveLine(try responseLine(id: copy.id, result: Stable.FsCopyResponse()))
    #expect(try await copyTask.value.isEmpty)

    let removeTask = Task {
      try await connection.fsRemove(
        .init(
          force: true,
          path: "/tmp/swift-codex/project/copy.txt",
          recursive: false
        ))
    }
    guard case .fsRemoveRequest(let remove) = try await nextRequest(peer) else {
      Issue.record("Expected fs/remove generated request.")
      return
    }
    #expect(remove.method == .fsRemove)
    #expect(remove.params.force == true)
    peer.receiveLine(try responseLine(id: remove.id, result: Stable.FsRemoveResponse()))
    #expect(try await removeTask.value.isEmpty)

    let watchTask = Task {
      try await connection.fsWatch(
        .init(
          path: "/tmp/swift-codex/project",
          watchId: "watch-1"
        ))
    }
    guard case .fsWatchRequest(let watch) = try await nextRequest(peer) else {
      Issue.record("Expected fs/watch generated request.")
      return
    }
    #expect(watch.method == .fsWatch)
    #expect(watch.params.watchId == "watch-1")
    peer.receiveLine(
      try responseLine(
        id: watch.id,
        result: Stable.FsWatchResponse(path: "/tmp/swift-codex/project")
      ))
    #expect(try await watchTask.value.path == "/tmp/swift-codex/project")

    let unwatchTask = Task {
      try await connection.fsUnwatch(.init(watchId: "watch-1"))
    }
    guard case .fsUnwatchRequest(let unwatch) = try await nextRequest(peer) else {
      Issue.record("Expected fs/unwatch generated request.")
      return
    }
    #expect(unwatch.method == .fsUnwatch)
    #expect(unwatch.params.watchId == "watch-1")
    peer.receiveLine(try responseLine(id: unwatch.id, result: Stable.FsUnwatchResponse()))
    #expect(try await unwatchTask.value.isEmpty)

    await connection.close()
  }

  @Test("Filesystem changes arrive on the notification stream")
  func filesystemChangesArriveOnNotificationStream() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startFilesystemReadyConnection(peer: peer)
    var rawNotifications = connection.notifications.makeAsyncIterator()

    peer.receiveLine(
      try fsChangedNotificationLine(
        changedPaths: ["/tmp/swift-codex/project/file.txt"],
        watchId: "watch-1"
      ))

    guard case .fsChangedNotification(let raw) = try await rawNotifications.next() else {
      Issue.record("Expected raw fs/changed notification.")
      return
    }
    #expect(raw.params.watchId == "watch-1")
    #expect(raw.params.changedPaths == ["/tmp/swift-codex/project/file.txt"])

    await connection.close()
  }

  @Test("Filesystem pending request fails when connection closes")
  func filesystemPendingRequestFailsWhenConnectionCloses() async throws {
    let peer = CodexAppServerInMemoryLinePeer()
    let connection = try await startFilesystemReadyConnection(peer: peer)

    let requestTask = Task {
      try await connection.fsReadFile(.init(path: "/tmp/swift-codex/project/slow.txt"))
    }

    let clientRequest = try await nextRequest(peer)
    guard case .fsReadFileRequest(let request) = clientRequest else {
      Issue.record("Expected fs/readFile generated request.")
      return
    }
    #expect(request.params.path == "/tmp/swift-codex/project/slow.txt")

    await connection.close()

    do {
      _ = try await requestTask.value
      Issue.record("Expected close failure.")
    } catch let error as CodexAppServerClientError {
      #expect(error == .closed)
    }
  }

}
private func startFilesystemReadyConnection(
  peer: CodexAppServerInMemoryLinePeer
) async throws -> CodexAppServerConnection {
  let startTask = Task {
    try await makeFilesystemClient(peer: peer).start()
  }

  let initializeLine = await peer.nextSentLine()
  let initializeRequest = try CodexAppServerProtocolContractSupport.Initialize
    .decodeInitializeRequest(from: initializeLine)
  peer.receiveLine(try initializeResponseLine(id: initializeRequest.id))

  let initializedLine = await peer.nextSentLine()
  _ = try CodexAppServerProtocolContractSupport.Initialize
    .decodeInitializedNotification(from: initializedLine)

  return try await startTask.value
}

private func makeFilesystemClient(peer: CodexAppServerInMemoryLinePeer) -> CodexAppServerClient {
  CodexAppServerClient(
    sessionConfiguration: .init(
      clientInfo: .init(
        name: "swift_codex_filesystem_tests",
        title: "swift-codex Filesystem Tests",
        version: "0.1.0"
      )
    ),
    transportFactory: {
      peer
    }
  )
}

private func nextRequest(_ peer: CodexAppServerInMemoryLinePeer) async throws
  -> Stable.ClientRequest
{
  try decode(Stable.ClientRequest.self, from: await peer.nextSentLine())
}

private func initializeResponseLine(id: Stable.RequestId) throws -> String {
  try CodexAppServerProtocolContractSupport.Initialize.encodeInitializeResponseLine(
    id: id,
    response: .init(
      codexHome: "/tmp/swift-codex/codex-home",
      platformFamily: "unix",
      platformOs: "macos",
      userAgent: "Codex/swift-codex-filesystem-fixture"
    )
  )
}

private func responseLine<T: Encodable>(
  id: Stable.RequestId,
  result: T
) throws -> String {
  try CodexAppServerConnectionFoundation.encodeLine(
    Stable.JSONRPCResponse(id: id, result: try Stable.JSONValue(result))
  )
}

private func fsChangedNotificationLine(
  changedPaths: [String],
  watchId: String
) throws -> String {
  try CodexAppServerConnectionFoundation.encodeLine(
    Stable.ServerNotification.fsChangedNotification(
      .init(
        method: .fsChanged,
        params: .init(changedPaths: changedPaths, watchId: watchId)
      ))
  )
}

private func decode<T: Decodable>(_ type: T.Type, from line: String) throws -> T {
  try JSONDecoder().decode(type, from: Data(line.utf8))
}
