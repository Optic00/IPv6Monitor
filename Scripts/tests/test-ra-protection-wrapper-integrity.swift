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

    try? FileManager.default.removeItem(atPath: tmp)
    exit(Int32(failures))
  }
}
