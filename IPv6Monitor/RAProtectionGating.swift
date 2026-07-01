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
