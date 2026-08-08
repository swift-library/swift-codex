import Foundation
import Testing

@testable import _CodexAppServerProtocolGeneratorCore

@Suite("CodexAppServer protocol generator")
struct CodexAppServerProtocolGeneratorTests {
  @Test("planner matches the pinned upstream schema inventory")
  func plannerMatchesPinnedUpstreamSchemaInventory() throws {
    let plan = try makeGenerationPlan()

    #expect(plan.entries.count == 1_335)
    #expect(plan.entries.filter { $0.surface == .stable }.count == 626)
    #expect(plan.entries.filter { $0.surface == .experimental }.count == 709)
    #expect(plan.unsupportedConstructUses.isEmpty)
    #expect(Set(plan.entries.map(\.outputRelativePath)).count == plan.entries.count)
  }

  @Test("planner keeps representative upstream surfaces in stable output buckets")
  func plannerKeepsRepresentativeUpstreamSurfacesInStableOutputBuckets() throws {
    let plan = try makeGenerationPlan()

    try expectEntry(
      in: plan,
      surface: .stable,
      typeName: "InitializeParams",
      outputRelativePath: "Stable/V1/InitializeParams+Stable.swift"
    )
    try expectEntry(
      in: plan,
      surface: .stable,
      typeName: "ThreadStartParams",
      outputRelativePath: "Stable/V2/Requests/ThreadStartParams+Stable.swift"
    )
    try expectEntry(
      in: plan,
      surface: .stable,
      typeName: "TurnStartResponse",
      outputRelativePath: "Stable/V2/Responses/TurnStartResponse+Stable.swift"
    )
    try expectEntry(
      in: plan,
      surface: .stable,
      typeName: "CommandExecParams",
      outputRelativePath: "Stable/V2/Requests/CommandExecParams+Stable.swift"
    )
    try expectEntry(
      in: plan,
      surface: .stable,
      typeName: "ServerRequest",
      outputRelativePath: "Stable/JSONRPC/ServerRequest+Stable.swift"
    )
    try expectEntry(
      in: plan,
      surface: .stable,
      typeName: "CommandExecutionRequestApprovalParams",
      outputRelativePath:
        "Stable/V2/ServerRequests/CommandExecutionRequestApprovalParams+Stable.swift"
    )
    try expectEntry(
      in: plan,
      surface: .stable,
      typeName: "WarningNotification",
      outputRelativePath: "Stable/V2/Notifications/WarningNotification+Stable.swift"
    )
    try expectEntry(
      in: plan,
      surface: .stable,
      typeName: "GetAccountTokenUsageResponse",
      outputRelativePath: "Stable/V2/Responses/GetAccountTokenUsageResponse+Stable.swift"
    )
    try expectEntry(
      in: plan,
      surface: .stable,
      typeName: "AttestationGenerateParams",
      outputRelativePath: "Stable/V2/ServerRequests/AttestationGenerateParams+Stable.swift"
    )
  }

  @Test("planner keeps experimental-only surfaces separate from stable output")
  func plannerKeepsExperimentalOnlySurfacesSeparateFromStableOutput() throws {
    let plan = try makeGenerationPlan()

    try expectEntry(
      in: plan,
      surface: .experimental,
      typeName: "ThreadRealtimeStartParams",
      outputRelativePath: "Experimental/V2/Requests/ThreadRealtimeStartParams+Experimental.swift"
    )

    let stableThreadRealtimeStart = plan.entries.first {
      $0.surface == .stable && $0.typeName == "ThreadRealtimeStartParams"
    }
    #expect(stableThreadRealtimeStart == nil)
  }

  @Test("emitter writes namespace, support, and representative type files")
  func emitterWritesNamespaceSupportAndRepresentativeTypeFiles() throws {
    let outputRoot = temporaryDirectory().appendingPathComponent("Generated")
    let plan = try makeGenerationPlan(outputRoot: outputRoot)

    try plan.validateForGeneration()
    try SwiftEmitter(plan: plan).emit()

    try expectFileContains(
      outputRoot.appendingPathComponent("CodexAppServerProtocol.swift"),
      "public enum CodexAppServerProtocol {}"
    )
    try expectFileContains(
      outputRoot.appendingPathComponent("Stable/CodexAppServerProtocol+Stable.swift"),
      "public enum Stable {}"
    )
    try expectFileContains(
      outputRoot.appendingPathComponent("Experimental/CodexAppServerProtocol+Experimental.swift"),
      "public enum Experimental {}"
    )
    try expectFileContains(
      outputRoot.appendingPathComponent("Stable/V2/Requests/ThreadStartParams+Stable.swift"),
      "extension CodexAppServerProtocol.Stable"
    )
    try expectFileContains(
      outputRoot.appendingPathComponent(
        "Experimental/V2/Requests/ThreadRealtimeStartParams+Experimental.swift"),
      "extension CodexAppServerProtocol.Experimental"
    )
  }

  @Test("client binding emitter writes representative stable and experimental wrappers")
  func clientBindingEmitterWritesRepresentativeWrappers() throws {
    let outputRoot = temporaryDirectory().appendingPathComponent("ClientBindings")
    let plan = try makeClientBindingPlan(outputRoot: outputRoot)

    try plan.validateForGeneration()
    try ClientBindingEmitter(plan: plan).emit()

    #expect(plan.bindings.count == 128)
    #expect(plan.bindings.filter { $0.surface == .stable }.count == 93)
    #expect(plan.bindings.filter { $0.surface == .experimental }.count == 35)
    try expectFileContains(
      outputRoot.appendingPathComponent("CodexAppServerClient+StableBindings.swift"),
      "public func threadStart("
    )
    try expectFileContains(
      outputRoot.appendingPathComponent("CodexAppServerClient+StableBindings.swift"),
      "responseType: CodexAppServerProtocol.Stable.ThreadStartResponse.self"
    )
    try expectFileContains(
      outputRoot.appendingPathComponent("CodexAppServerClient+StableBindings.swift"),
      "public func accountUsageRead()"
    )
    try expectFileContains(
      outputRoot.appendingPathComponent("CodexAppServerClient+StableBindings.swift"),
      "responseType: CodexAppServerProtocol.Stable.GetAccountTokenUsageResponse.self"
    )
    try expectFileContains(
      outputRoot.appendingPathComponent("CodexAppServerClient+ExperimentalBindings.swift"),
      "public func threadRealtimeStart("
    )
    try expectFileContains(
      outputRoot.appendingPathComponent("CodexAppServerClient+ExperimentalBindings.swift"),
      "_ params: CodexAppServerProtocol.Experimental.ThreadRealtimeListVoicesParams = [:]"
    )
    try expectFileContains(
      outputRoot.appendingPathComponent("CodexAppServerClient+ExperimentalBindings.swift"),
      "responseType: CodexAppServerProtocol.Experimental.ThreadRealtimeStartResponse.self"
    )
    try expectFileContains(
      outputRoot.appendingPathComponent("CodexAppServerClient+MethodPolicy.swift"),
      "\"fuzzyFileSearch\""
    )
    let generatedBindings = plan.bindings.map(\.method)
    #expect(!generatedBindings.contains("fuzzyFileSearch"))
    #expect(!generatedBindings.contains("fuzzyFileSearch/sessionStart"))
    #expect(!generatedBindings.contains("fuzzyFileSearch/sessionUpdate"))
    #expect(!generatedBindings.contains("fuzzyFileSearch/sessionStop"))
  }
}

private func makeGenerationPlan(
  outputRoot: URL = temporaryDirectory().appendingPathComponent("Generated")
) throws -> GenerationPlan {
  try GenerationPlanner(
    schemaRoot: packageRoot().appendingPathComponent("Vendor/CodexAppServerProtocolSchema"),
    outputRoot: outputRoot
  ).buildPlan()
}

private func makeClientBindingPlan(
  outputRoot: URL = temporaryDirectory().appendingPathComponent("ClientBindings")
) throws -> ClientBindingPlan {
  try ClientBindingPlanner(
    schemaRoot: packageRoot().appendingPathComponent("Vendor/CodexAppServerProtocolSchema"),
    outputRoot: outputRoot
  ).buildPlan()
}

private func expectEntry(
  in plan: GenerationPlan,
  surface: Surface,
  typeName: String,
  outputRelativePath: String,
  sourceLocation: SourceLocation = #_sourceLocation
) throws {
  let entry = plan.entries.first {
    $0.surface == surface && $0.typeName == typeName
  }

  #expect(
    entry != nil, "Missing generated entry for \(surface.rawValue) \(typeName).",
    sourceLocation: sourceLocation)
  #expect(entry?.outputRelativePath == outputRelativePath, sourceLocation: sourceLocation)
}

private func expectFileContains(
  _ fileURL: URL,
  _ expectedText: String,
  sourceLocation: SourceLocation = #_sourceLocation
) throws {
  let contents = try String(contentsOf: fileURL, encoding: .utf8)
  #expect(contents.contains(expectedText), sourceLocation: sourceLocation)
}

private func packageRoot() throws -> URL {
  var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  while directory.path != directory.deletingLastPathComponent().path {
    let packageManifest = directory.appendingPathComponent("Package.swift")
    let schemaRoot = directory.appendingPathComponent("Vendor/CodexAppServerProtocolSchema")
    if FileManager.default.fileExists(atPath: packageManifest.path),
      FileManager.default.fileExists(atPath: schemaRoot.path)
    {
      return directory
    }
    directory.deleteLastPathComponent()
  }

  throw TestSupportError.packageRootNotFound
}

private func temporaryDirectory() -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("swift-codex-\(UUID().uuidString)", isDirectory: true)
}

private enum TestSupportError: Error {
  case packageRootNotFound
}
