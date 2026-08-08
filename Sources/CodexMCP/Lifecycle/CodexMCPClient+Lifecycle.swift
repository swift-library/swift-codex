import Foundation

extension CodexMCPClient {
  /// Starts the upstream `codex mcp-server` process and initializes MCP.
  public func start() async throws {
    switch state {
    case .idle:
      state = .starting
      let startupTask = Task { [client = self] in
        try await client.performStartTransition()
      }
      self.startupTask = startupTask
      try await startupTask.value
    case .starting:
      guard let startupTask else {
        throw CodexMCPError.startupFailure
      }
      try await startupTask.value
    case .running:
      return
    case .stopping, .stopped, .failed:
      throw CodexMCPError.invalidStateTransition(operation: .start, from: state)
    }
  }

  /// Stops the MCP adapter and terminates the upstream process.
  public func stop() async throws {
    switch state {
    case .idle:
      return
    case .starting:
      state = .stopping
      _ = await startupTask?.result
      await protocolAdapter?.stop()
      subprocess = nil
      protocolAdapter = nil
      startupMetadata = nil
      state = .stopped
    case .running:
      state = .stopping
      do {
        await protocolAdapter?.stop()
        let subprocessToStop = subprocess
        try await subprocessToStop?.terminate()
        subprocessToStop?.closeIO()
        subprocess = nil
        protocolAdapter = nil
        startupMetadata = nil
        try await lifecycleShellHooks.onStopTransition?()
        state = .stopped
      } catch let error as CodexMCPError {
        state = .failed
        throw error
      } catch {
        state = .failed
        throw CodexMCPError.processFailure(
          stage: .stop,
          context: .init(
            message: error.localizedDescription,
            stderr: await subprocess?.stderrContext()
          )
        )
      }
    case .stopping, .stopped:
      return
    case .failed:
      await protocolAdapter?.stop()
      try? await subprocess?.terminate()
      subprocess?.closeIO()
      subprocess = nil
      protocolAdapter = nil
      startupMetadata = nil
      state = .stopped
    }
  }
}

extension CodexMCPClient {
  func launchConfiguration() -> CodexMCPSubprocessLaunchConfiguration {
    let executableURL: URL
    let arguments: [String]

    if let overrideExecutableURL = launchOptions.executableURL {
      executableURL = overrideExecutableURL
      arguments = ["mcp-server"]
    } else {
      executableURL = URL(fileURLWithPath: "/usr/bin/env")
      arguments = ["codex", "mcp-server"]
    }

    return CodexMCPSubprocessLaunchConfiguration(
      executableURL: executableURL,
      arguments: arguments,
      currentDirectoryURL: launchOptions.currentDirectoryURL,
      environment: launchOptions.environment,
    )
  }

  func performStartTransition() async throws {
    defer {
      startupTask = nil
    }

    var launchedSubprocess: CodexMCPManagedSubprocess?
    do {
      let startedSubprocess = try await subprocessLauncher.launch(
        launchConfiguration()
      )
      launchedSubprocess = startedSubprocess
      try ensureStartCanContinue()

      let protocolAdapter = try CodexMCPProtocolClientAdapter.make(
        subprocess: startedSubprocess,
        clientInfo: clientInfo
      )
      self.subprocess = startedSubprocess
      self.protocolAdapter = protocolAdapter

      let startupMetadata = try await protocolAdapter.start()
      try ensureStartCanContinue()

      self.startupMetadata = startupMetadata
      try await lifecycleShellHooks.onStartTransition?()
      try ensureStartCanContinue()

      state = .running
    } catch StartTransitionInterruption.stopRequested {
      await cleanupInterruptedRuntime(launchedSubprocess: launchedSubprocess)
      state = .stopped
      throw CodexMCPError.invalidStateTransition(operation: .start, from: .stopped)
    } catch let error as CodexMCPError {
      let stderr = await launchedSubprocess?.stderrContext()
      await cleanupInterruptedRuntime(launchedSubprocess: launchedSubprocess)
      state = .failed
      if let stderr, !stderr.isEmpty {
        switch error {
        case .startupFailure:
          throw CodexMCPError.processFailure(
            stage: .startup,
            context: .init(message: String(describing: error), stderr: stderr)
          )
        case .transportFailure:
          throw CodexMCPError.processFailure(
            stage: .transport,
            context: .init(message: String(describing: error), stderr: stderr)
          )
        default:
          break
        }
      }
      throw error
    } catch {
      let stderr = await launchedSubprocess?.stderrContext()
      await cleanupInterruptedRuntime(launchedSubprocess: launchedSubprocess)
      state = .failed
      throw CodexMCPError.processFailure(
        stage: .launch,
        context: .init(message: error.localizedDescription, stderr: stderr)
      )
    }
  }

  func ensureStartCanContinue() throws {
    guard state == .starting else {
      throw StartTransitionInterruption.stopRequested
    }
  }

  func cleanupInterruptedRuntime(launchedSubprocess: CodexMCPManagedSubprocess?) async {
    await protocolAdapter?.stop()
    startupMetadata = nil
    protocolAdapter = nil
    subprocess = nil
    try? await launchedSubprocess?.terminate()
    launchedSubprocess?.closeIO()
  }
}

private enum StartTransitionInterruption: Error {
  case stopRequested
}
