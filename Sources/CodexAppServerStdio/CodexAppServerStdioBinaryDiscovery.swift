import Foundation

extension CodexAppServerStdioConfiguration {
  package func resolveExecutable(
    environment inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> CodexAppServerStdioBinaryResolution {
    if let executableURL {
      return try resolveExplicitExecutable(executableURL)
    }

    guard !executableName.isEmpty else {
      throw CodexAppServerStdioError.invalidConfiguration(
        "Executable name must not be empty."
      )
    }

    guard !executableName.contains("/") else {
      throw CodexAppServerStdioError.invalidConfiguration(
        "Executable name must be a bare command name; use executableURL for paths."
      )
    }

    let effectiveEnvironment = environment ?? inheritedEnvironment
    let pathValue = effectiveEnvironment["PATH"] ?? ""
    for rawDirectory in pathValue.split(separator: ":") {
      let directory = String(rawDirectory)
      let candidate = URL(fileURLWithPath: directory, isDirectory: true)
        .appendingPathComponent(executableName)
      if FileManager.default.isExecutableFile(atPath: candidate.path) {
        return CodexAppServerStdioBinaryResolution(
          executableURL: candidate,
          source: .pathSearch(directory: directory)
        )
      }
    }

    throw CodexAppServerStdioError.executableNotFound(
      "Unable to resolve the `\(executableName)` executable from PATH."
    )
  }

  package func validateBinaryCompatibility(
    environment inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> CodexAppServerStdioBinaryCompatibilityReport {
    let resolution = try resolveExecutable(environment: inheritedEnvironment)

    switch versionRequirement {
    case .disabled:
      return CodexAppServerStdioBinaryCompatibilityReport(resolution: resolution)
    case .outputContains(let expectedSubstring):
      guard !expectedSubstring.isEmpty else {
        throw CodexAppServerStdioError.invalidConfiguration(
          "Version output requirement must not be empty."
        )
      }
      guard !versionProbeArguments.isEmpty else {
        throw CodexAppServerStdioError.invalidConfiguration(
          "Version probe arguments must not be empty when version checking is enabled."
        )
      }
      guard versionProbeTimeoutSeconds > 0 else {
        throw CodexAppServerStdioError.invalidConfiguration(
          "Version probe timeout must be greater than zero."
        )
      }

      let probe = try runVersionProbe(
        executableURL: resolution.executableURL,
        environment: environment ?? inheritedEnvironment
      )

      guard probe.exitStatus == 0 else {
        throw CodexAppServerStdioError.executableVersionProbeFailed(
          executable: resolution.executableURL.path,
          exitStatus: probe.exitStatus,
          stderr: probe.stderrText
        )
      }

      guard probe.combinedOutputText.contains(expectedSubstring) else {
        throw CodexAppServerStdioError.executableVersionMismatch(
          expectedSubstring: expectedSubstring,
          actualOutput: probe.combinedOutputText
        )
      }

      return CodexAppServerStdioBinaryCompatibilityReport(
        resolution: resolution,
        versionProbe: probe
      )
    }
  }

  private func resolveExplicitExecutable(
    _ executableURL: URL
  ) throws -> CodexAppServerStdioBinaryResolution {
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: executableURL.path, isDirectory: &isDirectory)
    else {
      throw CodexAppServerStdioError.executableNotFound(
        "Configured executable does not exist: \(executableURL.path)"
      )
    }

    guard !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: executableURL.path)
    else {
      throw CodexAppServerStdioError.executableNotExecutable(executableURL.path)
    }

    return CodexAppServerStdioBinaryResolution(
      executableURL: executableURL,
      source: .explicitURL
    )
  }

  private func runVersionProbe(
    executableURL: URL,
    environment effectiveEnvironment: [String: String]
  ) throws -> CodexAppServerStdioBinaryVersionProbe {
    let process = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()

    process.executableURL = executableURL
    process.arguments = versionProbeArguments
    process.environment = effectiveEnvironment
    process.currentDirectoryURL = workingDirectoryURL
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
      try process.run()
    } catch {
      throw CodexAppServerStdioError.launchFailure(error.localizedDescription)
    }

    if !waitForVersionProbeExit(process) {
      process.terminate()
      process.waitUntilExit()
      throw CodexAppServerStdioError.executableVersionProbeTimedOut(
        executable: executableURL.path,
        timeoutSeconds: versionProbeTimeoutSeconds
      )
    }

    let stdoutText = String(
      decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
      as: UTF8.self
    )
    let stderrText = String(
      decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
      as: UTF8.self
    )

    return CodexAppServerStdioBinaryVersionProbe(
      arguments: versionProbeArguments,
      stdoutText: stdoutText,
      stderrText: stderrText,
      exitStatus: process.terminationStatus
    )
  }

  private func waitForVersionProbeExit(_ process: Process) -> Bool {
    let deadline = Date().addingTimeInterval(versionProbeTimeoutSeconds)
    while process.isRunning {
      if Date() >= deadline {
        return false
      }
      Thread.sleep(forTimeInterval: 0.01)
    }
    return true
  }
}
