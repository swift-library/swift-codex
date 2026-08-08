import Foundation

/// Client for launching upstream `codex exec` and `codex exec resume`.
public struct CodexExecClient: Sendable {
  /// Launch configuration used for every request issued by this client.
  public let configuration: CodexExecLaunchConfiguration

  private let launcher: any CodexExecLaunching
  let executableResolver: CodexExecExecutableResolver

  /// Creates an exec client backed by the system process launcher.
  public init(configuration: CodexExecLaunchConfiguration = .init()) {
    self.configuration = configuration
    self.launcher = CodexExecSystemLauncher()
    self.executableResolver = CodexExecExecutableResolver()
  }

  init(
    configuration: CodexExecLaunchConfiguration = .init(),
    launcher: any CodexExecLaunching,
    executableResolver: CodexExecExecutableResolver = CodexExecExecutableResolver()
  ) {
    self.configuration = configuration
    self.launcher = launcher
    self.executableResolver = executableResolver
  }

  /// Starts a fresh non-interactive upstream exec run.
  public func run(_ request: CodexExecRunRequest) async throws -> CodexExecProcessHandle {
    try await execute(operation: .run, launchKind: .run(request))
  }

  /// Resumes an upstream exec session using the request selector.
  public func resume(_ request: CodexExecResumeRequest) async throws -> CodexExecProcessHandle {
    try await execute(operation: .resume, launchKind: .resume(request))
  }

  private func execute(
    operation: CodexExecOperation,
    launchKind: CodexExecLaunchKind
  ) async throws -> CodexExecProcessHandle {
    let requestSemantics = requestSemantics(for: launchKind)
    try validatePreLaunchRequestSemantics(requestSemantics)

    let preparedLaunch = try makePreparedLaunch(for: launchKind)
    let launchedProcess: CodexExecLaunchedProcess

    do {
      launchedProcess = try await launcher.launch(preparedLaunch)
    } catch let error as CodexExecLaunchCancelled {
      throw cancelledError(for: launchKind, launchError: error)
    } catch let error as CodexExecError {
      throw error
    } catch {
      throw CodexExecError.launchFailure(description: error.localizedDescription)
    }

    return CodexExecProcessHandle(
      stdoutLines: launchedProcess.stdoutLines,
      waiter: {
        let decoder = CodexExecJSONLDecoder()

        do {
          let output = try await launchedProcess.waitForOutput()
          let collectedStdoutLines = await launchedProcess.collectedStdoutLines()
          return try makeTermination(
            operation: operation,
            launchKind: launchKind,
            requestSemantics: requestSemantics,
            preparedLaunch: preparedLaunch,
            output: output,
            collectedStdoutLines: collectedStdoutLines,
            decoder: decoder
          )
        } catch let error as CodexExecLaunchCancelled {
          let collectedStdoutLines = await launchedProcess.collectedStdoutLines()
          throw cancelledError(
            for: launchKind,
            launchError: error,
            collectedStdoutLines: collectedStdoutLines,
            decoder: decoder
          )
        } catch let error as CodexExecError {
          throw error
        } catch {
          throw CodexExecError.launchFailure(description: error.localizedDescription)
        }
      }
    )
  }
}
