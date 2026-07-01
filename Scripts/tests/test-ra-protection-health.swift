// Scripts/tests/test-ra-protection-health.swift
import Foundation
var failures = 0
func check<T: Equatable>(_ desc: String, _ expected: T, _ actual: T) {
  if expected == actual { print("ok - \(desc)") } else { print("FAIL - \(desc): expected [\(expected)] got [\(actual)]"); failures += 1 }
}

@main struct Tests {
  static func main() {
    let now = Date()
    check(
      "anchor gone overrides everything", RAProtectionHealth.Verdict.autoOffAnchorGone,
      RAProtectionHealth.evaluate(active: false, ifaceMatches: true, now: now, lastPassIncreaseAt: now))
    check(
      "interface change detected", RAProtectionHealth.Verdict.autoOffInterfaceChanged,
      RAProtectionHealth.evaluate(active: true, ifaceMatches: false, now: now, lastPassIncreaseAt: now))
    check(
      "ok when pass increased recently", RAProtectionHealth.Verdict.ok,
      RAProtectionHealth.evaluate(active: true, ifaceMatches: true, now: now, lastPassIncreaseAt: now.addingTimeInterval(-60)))
    check(
      "ok right at the threshold boundary", RAProtectionHealth.Verdict.ok,
      RAProtectionHealth.evaluate(
        active: true, ifaceMatches: true, now: now,
        lastPassIncreaseAt: now.addingTimeInterval(-RAProtectionHealth.stallThresholdSeconds)))
    check(
      "stalled just past the threshold", RAProtectionHealth.Verdict.autoOffPassStalled,
      RAProtectionHealth.evaluate(
        active: true, ifaceMatches: true, now: now,
        lastPassIncreaseAt: now.addingTimeInterval(-RAProtectionHealth.stallThresholdSeconds - 1)))
    check(
      "anchor gone wins over interface mismatch and stall", RAProtectionHealth.Verdict.autoOffAnchorGone,
      RAProtectionHealth.evaluate(
        active: false, ifaceMatches: false, now: now,
        lastPassIncreaseAt: now.addingTimeInterval(-RAProtectionHealth.stallThresholdSeconds - 1)))
    check(
      "interface change wins over stall when anchor active", RAProtectionHealth.Verdict.autoOffInterfaceChanged,
      RAProtectionHealth.evaluate(
        active: true, ifaceMatches: false, now: now,
        lastPassIncreaseAt: now.addingTimeInterval(-RAProtectionHealth.stallThresholdSeconds - 1)))
    exit(Int32(failures))
  }
}
