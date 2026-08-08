import Foundation

@testable import CodexExec

actor RecordingLauncher: CodexExecLaunching {
  private var launches: [CodexExecPreparedLaunch] = []
  private let handler: @Sendable (CodexExecPreparedLaunch) throws -> CodexExecProcessOutput

  init(
    output: CodexExecProcessOutput = CodexExecProcessOutput(
      exitStatus: 0,
      terminationSignal: nil,
      standardOutput: Data(),
      standardError: Data()
    )
  ) {
    self.handler = { _ in output }
  }

  init(
    handler: @escaping @Sendable (CodexExecPreparedLaunch) throws -> CodexExecProcessOutput
  ) {
    self.handler = handler
  }

  func launch(_ launch: CodexExecPreparedLaunch) async throws -> CodexExecLaunchedProcess {
    launches.append(launch)

    let result: Result<CodexExecProcessOutput, Error>
    do {
      result = .success(try handler(launch))
    } catch {
      result = .failure(error)
    }

    let stdoutLines = makeStdoutStream(from: result)

    return CodexExecLaunchedProcess(
      stdoutLines: stdoutLines,
      waitForOutput: {
        try result.get()
      },
      collectedStdoutLines: {
        lines(from: result)
      }
    )
  }

  func recordedLaunches() -> [CodexExecPreparedLaunch] {
    launches
  }
}

func makeTemporaryDirectory(named prefix: String = "codexexec-tests") throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

func makeExecutableScript(
  in directory: URL,
  named name: String = "codex",
  contents: String
) throws -> URL {
  let scriptURL = directory.appendingPathComponent(name)
  try contents.write(to: scriptURL, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
  return scriptURL
}

private func makeStdoutStream(
  from result: Result<CodexExecProcessOutput, Error>
) -> AsyncThrowingStream<String, Error> {
  AsyncThrowingStream { continuation in
    switch result {
    case .success(let output):
      for line in lines(from: output) {
        continuation.yield(line)
      }
      continuation.finish()
    case .failure(let error):
      if let cancelled = error as? CodexExecLaunchCancelled,
        let processOutput = cancelled.processOutput
      {
        for line in lines(from: processOutput) {
          continuation.yield(line)
        }
        continuation.finish()
      } else {
        continuation.finish()
      }
    }
  }
}

private func lines(from result: Result<CodexExecProcessOutput, Error>) -> [String] {
  switch result {
  case .success(let output):
    return lines(from: output)
  case .failure(let error):
    if let cancelled = error as? CodexExecLaunchCancelled,
      let processOutput = cancelled.processOutput
    {
      return lines(from: processOutput)
    }
    return []
  }
}

private func lines(from output: CodexExecProcessOutput) -> [String] {
  let stdoutText = String(decoding: output.standardOutput, as: UTF8.self)
  guard !stdoutText.isEmpty else {
    return []
  }

  return stdoutText.split(
    separator: "\n",
    omittingEmptySubsequences: false
  ).map(String.init)
}

func collectLines(
  from stream: AsyncThrowingStream<String, Error>
) async throws -> [String] {
  var lines: [String] = []

  for try await line in stream {
    lines.append(line)
  }

  return lines
}

struct ObservedJSONLHandleOutput: Equatable, Sendable {
  var lines: [String]
  var events: [CodexExecEvent]
  var termination: CodexExecTermination
  var finalMessageText: String?
  var resolvedSessionID: String?
}

func observeJSONLHandle(
  _ handle: CodexExecProcessHandle
) async throws -> ObservedJSONLHandleOutput {
  let lines = try await collectLines(from: handle.stdoutLines)
  let decoder = CodexExecJSONLDecoder()
  let decoded = try decoder.inspect(lines: lines)
  let termination = try await handle.waitForTermination()

  return ObservedJSONLHandleOutput(
    lines: lines,
    events: decoded.events,
    termination: termination,
    finalMessageText: decoded.finalMessageText,
    resolvedSessionID: decoded.resolvedSessionID
  )
}
