// Scripts/tests/test-ra-protection-gating-visibility.swift
import Foundation
var failures = 0
func check<T: Equatable>(_ desc: String, _ expected: T, _ actual: T) {
  if expected == actual { print("ok - \(desc)") } else { print("FAIL - \(desc): expected [\(expected)] got [\(actual)]"); failures += 1 }
}

@main struct Tests {
  static func main() {
    check(
      "hidden without global IPv6", false,
      RAProtectionGating.isVisible(.init(hasGlobalIPv6: false, routerCount: 5, hadPriorRouteLoss: true)))
    check(
      "hidden with single router and no prior loss", false,
      RAProtectionGating.isVisible(.init(hasGlobalIPv6: true, routerCount: 1, hadPriorRouteLoss: false)))
    check(
      "visible with multiple routers", true,
      RAProtectionGating.isVisible(.init(hasGlobalIPv6: true, routerCount: 2, hadPriorRouteLoss: false)))
    check(
      "visible with prior route loss even at one router", true,
      RAProtectionGating.isVisible(.init(hasGlobalIPv6: true, routerCount: 1, hadPriorRouteLoss: true)))
    exit(Int32(failures))
  }
}
