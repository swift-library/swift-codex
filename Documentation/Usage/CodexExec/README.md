# CodexExec Usage

`CodexExec` is the process and protocol layer for the full upstream-documented
non-interactive `codex exec` and `codex exec resume` surfaces.

Use this product when your code needs:

- direct `codex exec` / `resume` argv-facing behavior
- raw stdout line streaming
- JSONL decoding into high-fidelity exec protocol types
- separate process termination metadata
- explicit control over prompt input, stdin, cwd, environment, and schema files

## Human-Readable Mode

```swift
import CodexExec

func runHumanReadable() async throws {
  let client = CodexExecClient()
  let handle = try await client.run(.init(
    promptInput: .text("Explain this package layout.")
  ))

  do {
    for try await line in handle.stdoutLines { print(line) }
  } catch {
    _ = try? await handle.waitForTermination()
    throw error
  }

  let termination = try await handle.waitForTermination()
  print(termination.exitInterpretation)
}
```

## JSONL Mode

```swift
import CodexExec

func runJSONL() async throws {
  let client = CodexExecClient()
  let handle = try await client.run(.init(
    promptInput: .text("Inspect Package.swift."),
    outputMode: .jsonl
  ))

  let events = CodexExecJSONLDecoder().decode(handle.stdoutLines)

  do {
    for try await event in events { print(event) }
  } catch {
    _ = try? await handle.waitForTermination()
    throw error
  }

  _ = try await handle.waitForTermination()
}
```

## Resume

```swift
import CodexExec

func resumeSession(id: String) async throws {
  let client = CodexExecClient()
  let handle = try await client.resume(.init(
    selector: .sessionID(id),
    promptInput: .text("Continue the previous task."),
    outputMode: .jsonl
  ))

  do {
    for try await event in CodexExecJSONLDecoder().decode(handle.stdoutLines) { print(event) }
  } catch {
    _ = try? await handle.waitForTermination()
    throw error
  }

  _ = try await handle.waitForTermination()
}
```

`CodexExecResumeSelector` also supports `.last` and `.lastAll`, matching the
upstream documented `codex exec resume` selectors.

## Launch And Request Options

```swift
import CodexExec
import Foundation

func runWithConfiguration() async throws {
  let client = CodexExecClient(configuration: .init(
    executableURL: URL(fileURLWithPath: "/usr/local/bin/codex"),
    apiKey: "example",
    defaultWorkingDirectory: URL(fileURLWithPath: "/path/to/workspace")
  ))

  let request = CodexExecRunRequest(
    promptInput: .textWithStdinContext(
      prompt: "Summarize stdin.",
      stdin: "large context"
    ),
    outputMode: .jsonl,
    options: .init(
      ignoreUserConfig: true,
      skipGitRepoCheck: true,
      configOverrides: ["sandbox_mode=\"workspace-write\""]
    )
  )

  let handle = try await client.run(request)
  _ = try await handle.waitForTermination()
}
```

Set `ignoreUserConfig` when an embedding application must prevent the user's
global models, MCP servers, hooks, or other `config.toml` settings from changing
the request. This maps to the upstream `--ignore-user-config` flag. Codex still
uses `CODEX_HOME` for authentication, so the caller does not need to copy or
inject login credentials.

## Output Contract

`CodexExec` is stream-first. `run(_:)` and `resume(_:)` return a
`CodexExecProcessHandle`. The handle exposes raw `stdoutLines`; process
completion is obtained separately through `waitForTermination()`.

JSONL interpretation is opt-in through `CodexExecJSONLDecoder`. Unknown
documented-forward-compatible events and items preserve raw JSON so callers can
continue processing without losing protocol data.

Capture is finite: `CodexExecLaunchConfiguration.outputLimits` defaults to
8 MiB and 65,536 complete stdout lines, plus 1 MiB stderr. Increase these
budgets explicitly for larger expected output. The SDK keeps a complete-line
stdout prefix and a byte stderr prefix while continuing to drain the process.
It never emits a partially retained JSONL line.

When output exceeds a budget, `outputCaptureLimitExceeded` exposes the retained
partial observation and its `outputCapture.stdoutDroppedBytes` and
`stderrDroppedBytes`. Native failures and cancellation retain those same
missing-output counts. A stdout stream error alone does not mean the process
has terminated: always await `waitForTermination()`, including after a stream
error, to settle process cleanup and inspect final stderr evidence.
