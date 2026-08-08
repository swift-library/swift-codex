import Foundation

struct ClientMethodAdoption: Sendable {
  static let filename = "method-adoption.json"
  static let schemaName = "swift-codex.codex-app-server-method-adoption.v1"

  let upstreamTag: String
  let stableMethods: Set<String>
  let experimentalMethods: Set<String>
  let exclusions: [Exclusion]

  var adoptedMethods: Set<String> {
    stableMethods.union(experimentalMethods)
  }

  var excludedMethods: Set<String> {
    Set(exclusions.map(\.method))
  }

  static func load(schemaRoot: URL) throws -> ClientMethodAdoption {
    let manifestURL = schemaRoot.appendingPathComponent(filename)
    let lockURL = schemaRoot.appendingPathComponent("upstream.lock.json")
    guard FileManager.default.fileExists(atPath: manifestURL.path) else {
      throw GeneratorError.missingInput("missing method adoption manifest: \(manifestURL.path)")
    }

    do {
      let manifest = try JSONDecoder().decode(
        Manifest.self,
        from: Data(contentsOf: manifestURL)
      )
      let lock = try JSONDecoder().decode(
        Lock.self,
        from: Data(contentsOf: lockURL)
      )
      guard manifest.schema == schemaName else {
        throw GeneratorError.invalidSchema(
          "unsupported method adoption manifest schema '\(manifest.schema)'"
        )
      }
      guard manifest.upstreamTag == lock.upstream.tag else {
        throw GeneratorError.invalidSchema(
          "method adoption tag \(manifest.upstreamTag) does not match lock tag \(lock.upstream.tag)"
        )
      }

      let adoption = ClientMethodAdoption(
        upstreamTag: manifest.upstreamTag,
        stableMethods: Set(manifest.adopted.stable),
        experimentalMethods: Set(manifest.adopted.experimental),
        exclusions: manifest.excluded
      )
      try adoption.validateManifestShape()
      return adoption
    } catch let error as GeneratorError {
      throw error
    } catch {
      throw GeneratorError.invalidSchema(
        "method adoption manifest decode failed: \(error.localizedDescription)"
      )
    }
  }

  func validate(
    stableSchemaMethods: Set<String>,
    experimentalSchemaMethods: Set<String>
  ) throws {
    let schemaMethods = stableSchemaMethods.union(experimentalSchemaMethods)
    let unknownAdoptions = adoptedMethods.subtracting(schemaMethods)
    guard unknownAdoptions.isEmpty else {
      throw GeneratorError.invalidSchema(
        "method adoption manifest contains methods absent from the pinned schema: "
          + unknownAdoptions.sorted().joined(separator: ", ")
      )
    }

    let classifiedSchemaMethods = adoptedMethods.union(excludedMethods.intersection(schemaMethods))
    let unclassifiedMethods = schemaMethods.subtracting(classifiedSchemaMethods)
    guard unclassifiedMethods.isEmpty else {
      throw GeneratorError.invalidSchema(
        "pinned client methods lack an adoption decision: "
          + unclassifiedMethods.sorted().joined(separator: ", ")
      )
    }

    let stableMisclassifications = stableMethods.subtracting(stableSchemaMethods)
    guard stableMisclassifications.isEmpty else {
      throw GeneratorError.invalidSchema(
        "stable adoption entries are not stable schema methods: "
          + stableMisclassifications.sorted().joined(separator: ", ")
      )
    }

    let experimentalOnlySchemaMethods = experimentalSchemaMethods.subtracting(stableSchemaMethods)
    let experimentalMisclassifications = experimentalMethods.subtracting(
      experimentalOnlySchemaMethods
    )
    guard experimentalMisclassifications.isEmpty else {
      throw GeneratorError.invalidSchema(
        "experimental adoption entries are not experimental-only schema methods: "
          + experimentalMisclassifications.sorted().joined(separator: ", ")
      )
    }
  }

  func includesTypedRequest(_ method: String) -> Bool {
    adoptedMethods.contains(method)
  }

  func rawDeniedMethods(for bindings: [ClientBinding]) -> [String] {
    Array(Set(bindings.map(\.method)).union(excludedMethods)).sorted()
  }

  private func validateManifestShape() throws {
    let duplicateClassifications = stableMethods.intersection(experimentalMethods)
      .union(adoptedMethods.intersection(excludedMethods))
    guard duplicateClassifications.isEmpty else {
      throw GeneratorError.invalidSchema(
        "method adoption decisions overlap: "
          + duplicateClassifications.sorted().joined(separator: ", ")
      )
    }

    guard exclusions.map(\.method) == exclusions.map(\.method).sorted() else {
      throw GeneratorError.invalidSchema("method adoption exclusions must be sorted")
    }
    guard exclusions.allSatisfy({ !$0.reason.trimmingCharacters(in: .whitespaces).isEmpty }) else {
      throw GeneratorError.invalidSchema("every method exclusion requires a reason")
    }
  }

  struct Exclusion: Codable, Equatable, Sendable {
    let method: String
    let reason: String
  }

  private struct Manifest: Decodable {
    let schema: String
    let upstreamTag: String
    let adopted: Adopted
    let excluded: [Exclusion]

    struct Adopted: Decodable {
      let stable: [String]
      let experimental: [String]
    }
  }

  private struct Lock: Decodable {
    let upstream: Upstream

    struct Upstream: Decodable {
      let tag: String
    }
  }
}
