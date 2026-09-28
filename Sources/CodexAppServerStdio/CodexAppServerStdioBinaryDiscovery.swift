import Foundation
import _CodexProcess

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

    guard CodexExecutableDiscovery.isBareName(executableName) else {
      throw CodexAppServerStdioError.invalidConfiguration(
        "Executable name must be a bare command name; use executableURL for paths."
      )
    }

    let effectiveEnvironment = environment ?? inheritedEnvironment
    do {
      if let result = try CodexExecutableDiscovery.find(
        named: executableName, environment: effectiveEnvironment)
      {
        return CodexAppServerStdioBinaryResolution(
          executableURL: result.executable,
          source: .pathSearch(directory: result.directory)
        )
      }
    } catch {
      throw CodexAppServerStdioError.invalidConfiguration(error.localizedDescription)
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
      guard versionProbeTimeoutSeconds.isFinite, versionProbeTimeoutSeconds > 0,
        versionProbeTimeoutSeconds <= 60
      else {
        throw CodexAppServerStdioError.invalidConfiguration(
          "Version probe timeout must be finite, greater than zero and at most 60 seconds."
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
    let result: CodexProcessProbeResult
    do {
      result = try CodexProcessProbe.run(
        executableURL: executableURL, arguments: versionProbeArguments,
        environment: effectiveEnvironment, workingDirectory: workingDirectoryURL,
        timeoutSeconds: versionProbeTimeoutSeconds, outputLimit: 65_536)
    } catch CodexProcessProbeError.timedOut {
      throw CodexAppServerStdioError.executableVersionProbeTimedOut(
        executable: executableURL.path, timeoutSeconds: versionProbeTimeoutSeconds)
    } catch CodexProcessProbeError.outputLimitExceeded {
      throw CodexAppServerStdioError.executableVersionProbeOutputLimitExceeded(
        executable: executableURL.path, limitBytes: 65_536)
    } catch {
      throw CodexAppServerStdioError.launchFailure(error.localizedDescription)
    }
    return CodexAppServerStdioBinaryVersionProbe(
      arguments: versionProbeArguments,
      stdoutText: String(decoding: result.stdout, as: UTF8.self),
      stderrText: String(decoding: result.stderr, as: UTF8.self),
      exitStatus: result.exit.status)
  }
}
