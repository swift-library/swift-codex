import Foundation

#if os(Windows)
  import WinSDK
#endif

package enum CodexProcessEnvironment {
  package static func value(for name: String, in environment: [String: String]) throws -> String? {
    var result: String?
    for (key, value) in environment where try compareNames(key, name) == 0 {
      guard result == nil else {
        throw CodexProcessFailure(description: "Process environment contains duplicate names.")
      }
      result = value
    }
    return result
  }

  package static func setting(
    _ value: String, for name: String, in environment: [String: String]
  ) throws -> [String: String] {
    var result = try environment.filter { try compareNames($0.key, name) != 0 }
    result[name] = value
    return result
  }

  /// Matches native environment-name identity, including Windows ordinal case rules.
  static func compareNames(_ left: String, _ right: String) throws -> Int {
    #if os(Windows)
      guard let leftCount = Int32(exactly: left.utf16.count),
        let rightCount = Int32(exactly: right.utf16.count)
      else { throw CodexProcessFailure(description: "Process environment name is too long.") }
      let result = left.withCString(encodedAs: UTF16.self) { left in
        right.withCString(encodedAs: UTF16.self) { right in
          CompareStringOrdinal(left, leftCount, right, rightCount, true)
        }
      }
      guard result != 0 else { throw CodexWindowsProcess.error("CompareStringOrdinal") }
      return Int(result) - Int(CSTR_EQUAL)
    #else
      return left == right ? 0 : left < right ? -1 : 1
    #endif
  }
}
