import Foundation

enum RAProtectionHealth {
  // Conservative upper bound for real-world RA intervals (RFC 4861 allows configuring up to
  // 600s = MaxRtrAdvInterval in many implementations). "2 RA intervals" per the design spec
  // is therefore 1200s — comfortably under the ~30 min the existing RA lifetime can keep a
  // route alive while the real gateway's RA is being blocked (the design spec's own rationale
  // for this check).
  static let assumedRAIntervalSeconds: TimeInterval = 600
  static let stallThresholdSeconds: TimeInterval = 2 * assumedRAIntervalSeconds

  enum Verdict: Equatable {
    case ok
    case autoOffAnchorGone
    case autoOffInterfaceChanged
    case autoOffPassStalled
  }

  static func evaluate(
    active: Bool,
    ifaceMatches: Bool,
    now: Date,
    lastPassIncreaseAt: Date,
    stallThreshold: TimeInterval = stallThresholdSeconds
  ) -> Verdict {
    guard active else { return .autoOffAnchorGone }
    guard ifaceMatches else { return .autoOffInterfaceChanged }
    guard now.timeIntervalSince(lastPassIncreaseAt) <= stallThreshold else {
      return .autoOffPassStalled
    }
    return .ok
  }
}
