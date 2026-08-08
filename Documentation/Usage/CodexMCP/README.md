# CodexMCP Usage

`CodexMCP` is a Swift client for the upstream Codex MCP server.

Use this product when your code needs:

- MCP lifecycle over the `codex mcp-server` process
- `ping` and `tools/list`
- `codex` tool invocation
- streamed server messages
- approval requests and responses
- cancellation

## Start And Stop

```swift
import CodexMCP

func connectMCP() async throws {
  let client = CodexMCPClient()

  try await client.start()
  do {
    try await client.ping()
    try await client.stop()
  } catch {
    try? await client.stop()
    throw error
  }
}
```

## List Tools

```swift
import CodexMCP

func listTools() async throws {
  let client = CodexMCPClient()
  try await client.start()
  do {
    let tools = try await client.listTools()
    for tool in tools {
      print(tool.name)
    }
    try await client.stop()
  } catch {
    try? await client.stop()
    throw error
  }
}
```

## Run Codex Through MCP

```swift
import CodexMCP

func runCodexTool() async throws {
  let client = CodexMCPClient()
  try await client.start()
  do {
    let handle = try await client.runCodex(.init(
      prompt: "Inspect this workspace."
    ))

    let messageTask = Task {
      for await message in handle.serverMessages {
        print(message)
      }
    }

    let approvalTask = Task {
      for await approval in handle.approvalRequests {
        try? await handle.respond(to: approval.requestID, with: .deny)
      }
    }
    defer {
      messageTask.cancel()
      approvalTask.cancel()
    }

    let result = try await handle.value()
    await messageTask.value
    await approvalTask.value
    print(result)
    try await client.stop()
  } catch {
    try? await client.stop()
    throw error
  }
}
```

## Reply And Cancel

```swift
import CodexMCP

func replyAndCancel(threadID: String) async throws {
  let client = CodexMCPClient()
  try await client.start()
  do {
    let handle = try await client.reply(.init(
      threadID: threadID,
      prompt: "Continue."
    ))

    _ = try await handle.cancel()
    try await client.stop()
  } catch {
    try? await client.stop()
    throw error
  }
}
```

`CodexMCPApprovalDecision` currently exposes `.allow` and `.deny`; the wire
values are translated to the upstream approval response values.
