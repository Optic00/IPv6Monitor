// Scripts/tests/test-ra-protection-wrapper-integrity.swift
import Foundation
var failures = 0
func check<T: Equatable>(_ desc: String, _ expected: T, _ actual: T) {
  if expected == actual { print("ok - \(desc)") } else { print("FAIL - \(desc): expected [\(expected)] got [\(actual)]"); failures += 1 }
}

@main struct Tests {
  static func main() {
    let tmp = NSTemporaryDirectory() + "ra-protection-integrity-test-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    let userOwnedFile = tmp + "/x"
    FileManager.default.createFile(atPath: userOwnedFile, contents: Data())

    check("user-owned path is unsafe", false, RAProtectionWrapper.pathIsSafe(userOwnedFile))
    check("root-owned system path is safe", true, RAProtectionWrapper.pathIsSafe("/usr/bin/true"))
    check("nonexistent path is unsafe", false, RAProtectionWrapper.pathIsSafe("/no/such/path/here"))

    // Test resolveToAbsolute directly with string comparisons (no filesystem ownership gate)
    let originalCwd = FileManager.default.currentDirectoryPath
    FileManager.default.changeCurrentDirectoryPath("/usr/bin")
    check("resolves a bare relative filename against cwd", "/usr/bin/true", RAProtectionWrapper.resolveToAbsolute("true"))
    check("resolves a ./ relative path against cwd", "/usr/bin/true", RAProtectionWrapper.resolveToAbsolute("./true"))
    check("resolves a ../ relative path against cwd", "/usr/true", RAProtectionWrapper.resolveToAbsolute("../true"))
    check("passes through an absolute path unchanged", "/usr/bin/true", RAProtectionWrapper.resolveToAbsolute("/usr/bin/true"))
    FileManager.default.changeCurrentDirectoryPath(originalCwd)

    try? FileManager.default.removeItem(atPath: tmp)
    exit(Int32(failures))
  }
}
