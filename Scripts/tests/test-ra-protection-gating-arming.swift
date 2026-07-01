// Scripts/tests/test-ra-protection-gating-arming.swift
import Foundation
var failures = 0
func check<T: Equatable>(_ desc: String, _ expected: T, _ actual: T) {
  if expected == actual { print("ok - \(desc)") } else { print("FAIL - \(desc): expected [\(expected)] got [\(actual)]"); failures += 1 }
}

@main struct Tests {
  static func main() {
    check(
      "refuses when no gateway seen", RAProtectionGating.ArmingDecision.refusedNoFreshGateway,
      RAProtectionGating.evaluateArming(.init(gatewayFreshnessSeconds: nil, otherSendersCount: 3, gatewayCount: 0)))
    check(
      "refuses when gateway too stale", RAProtectionGating.ArmingDecision.refusedNoFreshGateway,
      RAProtectionGating.evaluateArming(.init(gatewayFreshnessSeconds: 999, otherSendersCount: 3, gatewayCount: 1)))
    check(
      "refuses when no other senders", RAProtectionGating.ArmingDecision.refusedNoOtherSenders,
      RAProtectionGating.evaluateArming(.init(gatewayFreshnessSeconds: 60, otherSendersCount: 0, gatewayCount: 1)))
    check(
      "allows single fresh gateway with other senders", RAProtectionGating.ArmingDecision.allowed,
      RAProtectionGating.evaluateArming(.init(gatewayFreshnessSeconds: 60, otherSendersCount: 3, gatewayCount: 1)))
    check(
      "needs confirmation for multiple gateways",
      RAProtectionGating.ArmingDecision.allowedNeedsMultiGatewayConfirmation,
      RAProtectionGating.evaluateArming(.init(gatewayFreshnessSeconds: 60, otherSendersCount: 3, gatewayCount: 2)))
    exit(Int32(failures))
  }
}
