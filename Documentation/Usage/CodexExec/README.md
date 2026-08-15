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

  for try await line in handle.stdoutLines {
    print(line)
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

  for try await event in events {
    print(event)
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

  for try await event in CodexExecJSONLDecoder().decode(handle.stdoutLines) {
    print(event)
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

  _ = try await client.run(request)
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
