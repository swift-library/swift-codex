# Codex Usage

`Codex` is the SDK object layer. It owns Swift-facing thread and turn
semantics while using `CodexExec` underneath for the current upstream-aligned
execution path.

Use this product when your app wants:

- `Codex` and `CodexThread` objects
- `run()` buffered convenience returning `Turn`
- `runStreamed()` event streaming
- SDK names for `ThreadEvent`, `ThreadItem`, `Usage`, and `ThreadError`

## Basic Run

```swift
import Codex

func runOneTurn() async throws {
  let codex = Codex()
  let thread = codex.startThread()

  let turn = try await thread.run(.text("Summarize Package.swift."))
  print(turn.finalResponse)
}
```

## Stream Events

```swift
import Codex

func streamTurn() async throws {
  let codex = Codex()
  let thread = codex.startThread()

  let streamedTurn = try await thread.runStreamed(.text("Inspect the test suite."))

  for try await event in streamedTurn {
    switch event {
    case let .threadStarted(id):
      print("thread:", id)
    case let .itemCompleted(item):
      print("item:", item)
    case let .turnCompleted(usage):
      print("usage:", String(describing: usage))
    default:
      break
    }
  }
}
```

## Resume A Thread

```swift
import Codex

func resumeThread(id: String) async throws {
  let codex = Codex()
  let thread = codex.resumeThread(id)

  let turn = try await thread.run(.text("Continue from the previous turn."))
  print(turn.finalResponse)
}
```

## Configure Execution

```swift
import Codex
import Foundation

func runWithOptions() async throws {
  let codex = Codex(options: .init(
    codexPathOverride: URL(fileURLWithPath: "/usr/local/bin/codex"),
    environment: ["OPENAI_API_KEY": "example"]
  ))

  let thread = codex.startThread(options: .init(
    workingDirectory: URL(fileURLWithPath: "/path/to/workspace"),
    skipGitRepoCheck: true
  ))

  _ = try await thread.run(.text("Review the current diff."))
}
```

## Protocol Types

`Codex` keeps SDK names public while reusing the canonical exec protocol types:

```swift
public typealias ThreadEvent = CodexExecEvent
public typealias ThreadItem = CodexExecItem
public typealias Usage = CodexExecUsage
public typealias ThreadError = CodexExecThreadError
```

This avoids duplicating the JSONL protocol model in the SDK layer. `Codex`
still owns SDK aggregation: `run()` consumes streamed events and builds the
buffered `Turn`.
