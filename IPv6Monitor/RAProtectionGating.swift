import Foundation

enum RAProtectionGating {
  struct RiskProfile: Equatable {
    let hasGlobalIPv6: Bool
    let routerCount: Int
    let hadPriorRouteLoss: Bool
  }

  // Per the design spec: hidden unless the primary interface has global IPv6 AND
  // (more than one RA sender is seen OR the log recorded a prior route loss).
  static func isVisible(_ profile: RiskProfile) -> Bool {
    guard profile.hasGlobalIPv6 else { return false }
    return profile.routerCount > 1 || profile.hadPriorRouteLoss
  }
}

extension RAProtectionGating {
  struct ArmingPrecheck: Equatable {
    let gatewayFreshnessSeconds: Double?  // nil = no gateway RA seen at all
    let otherSendersCount: Int
    let gatewayCount: Int
  }

  enum ArmingDecision: Equatable {
    case allowed
    case allowedNeedsMultiGatewayConfirmation
    case refusedNoFreshGateway
    case refusedNoOtherSenders
  }

  // `detect`'s sniff window is RAProtectionWrapper.defaultSniffSeconds (60s); a returned
  // gateway was seen sometime within that window, so 70s gives a small margin above the
  // 60s worst case rather than a tighter number the wrapper can't actually guarantee.
  static let freshnessThresholdSeconds: Double = 70

  static func evaluateArming(
    _ precheck: ArmingPrecheck, freshnessThreshold: Double = freshnessThresholdSeconds
  ) -> ArmingDecision {
    guard let freshness = precheck.gatewayFreshnessSeconds, freshness <= freshnessThreshold else {
      return .refusedNoFreshGateway
    }
    guard precheck.otherSendersCount > 0 else {
      return .refusedNoOtherSenders
    }
    return precheck.gatewayCount > 1 ? .allowedNeedsMultiGatewayConfirmation : .allowed
  }
}
