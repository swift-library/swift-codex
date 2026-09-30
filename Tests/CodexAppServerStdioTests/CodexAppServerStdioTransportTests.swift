#if canImport(Darwin)
  import Foundation
  import Testing

  @testable import CodexAppServerStdio

  @Suite("CodexAppServerStdio Transport", .timeLimit(.minutes(1)))
  struct CodexAppServerStdioTransportTests {
    @Test("Unexpected process exit carries bounded redacted stderr")
    func unexpectedProcessExitCarriesBoundedRedactedStderr() async throws {
      let executable = try makeTransportTestExecutable(
        contents: """
          #!/bin/sh
          echo 'fatal startup failure; Authorization: Bearer bearer-secret api_key=api-secret sk-live-secretvalue' >&2
          exit 42
          """
      )
      defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
      let transport = try CodexAppServerStdioTransport(
        configuration: .init(executableURL: executable, arguments: [])
      )

      var iterator = transport.inboundLines.makeAsyncIterator()
      do {
        _ = try await iterator.next()
        Issue.record("Expected the terminated process to fail the inbound stream.")
      } catch let error as CodexAppServerStdioError {
        guard case .processTerminated(let exitStatus, let diagnostic) = error else {
          Issue.record("Expected processTerminated, got \(error).")
          await transport.close()
          return
        }

        #expect(exitStatus == 42)
        #expect(diagnostic.contains("fatal startup failure"))
        #expect(diagnostic.contains("[REDACTED]"))
        #expect(!diagnostic.contains("bearer-secret"))
        #expect(!diagnostic.contains("api-secret"))
        #expect(!diagnostic.contains("sk-live-secretvalue"))
      }
      await transport.close()
    }

    @Test("A natural signal has no exit code and preserves its native termination reason")
    func signalledExitPreservesTerminationReason() async throws {
      let executable = try makeTransportTestExecutable(
        contents: """
          #!/bin/sh
          echo 'signal diagnostic' >&2
          kill -TERM $$
          """
      )
      defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
      let transport = try CodexAppServerStdioTransport(
        configuration: .init(executableURL: executable, arguments: []))
      do {
        var iterator = transport.inboundLines.makeAsyncIterator()
        do {
          _ = try await iterator.next()
          Issue.record("Expected a signalled process failure")
        } catch let error as CodexAppServerStdioError {
          guard case .processTerminated(let status, let diagnostic) = error else {
            Issue.record("Expected processTerminated")
            await transport.close()
            return
          }
          #expect(status == nil)
          #expect(diagnostic.contains("signal diagnostic"))
        }
        #expect(try await transport.waitForExit() == .signalled(15))
        await transport.close()
      } catch {
        await transport.close()
        throw error
      }
    }

    @Test("Explicit close finishes the inbound stream without a process failure")
    func explicitCloseFinishesInboundStreamNormally() async throws {
      let executable = try makeTransportTestExecutable(
        contents: """
          #!/bin/sh
          while read line; do
            echo "$line"
          done
          """
      )
      defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
      let transport = try CodexAppServerStdioTransport(
        configuration: .init(executableURL: executable, arguments: [])
      )
      var iterator = transport.inboundLines.makeAsyncIterator()

      await transport.close()

      #expect(try await iterator.next() == nil)
    }

    @Test("Stderr diagnostics retain only their configured tail")
    func stderrDiagnosticsRetainOnlyConfiguredTail() {
      let diagnostic = CodexAppServerProcessDiagnostic(byteLimit: 24)
      diagnostic.append(Data("discard-this-prefix-".utf8))
      diagnostic.append(Data("token=private\nuseful-tail".utf8))

      let snapshot = diagnostic.snapshot()

      #expect(snapshot.hasPrefix("[process output truncated; omitted "))
      #expect(snapshot.hasSuffix("useful-tail"))
      #expect(!snapshot.contains("private"))
      #expect(!snapshot.contains("discard-this-prefix"))
    }

    @Test("An oversized stderr line is discarded through its newline before retaining later output")
    func truncatedCredentialLineCannotExposeItsSuffix() {
      let diagnostic = CodexAppServerProcessDiagnostic(byteLimit: 32)
      diagnostic.append(Data(("token=" + String(repeating: "s", count: 100)).utf8))
      diagnostic.append(Data("secret-suffix".utf8))
      diagnostic.append(Data("\nuseful message\n".utf8))
      let snapshot = diagnostic.snapshot()
      #expect(snapshot.hasSuffix("useful message\n"))
      #expect(!snapshot.contains("secret-suffix"))
      #expect(!snapshot.contains("ssss"))
    }

    @Test("Stderr diagnostics redact common credential forms")
    func stderrDiagnosticsRedactCommonCredentialForms() {
      let diagnostic = CodexAppServerProcessDiagnostic(byteLimit: 1_024)
      diagnostic.append(
        Data(
          "Authorization: Bearer bearer-secret api_key=api-secret sk-live-secretvalue\n".utf8
        )
      )

      let snapshot = diagnostic.snapshot()

      #expect(snapshot.contains("[REDACTED]"))
      #expect(!snapshot.contains("bearer-secret"))
      #expect(!snapshot.contains("api-secret"))
      #expect(!snapshot.contains("sk-live-secretvalue"))
    }
  }

  private func makeTransportTestExecutable(contents: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("appserver-transport-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = directory.appendingPathComponent("codex-test-server")
    try contents.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executable.path
    )
    return executable
  }

#endif
