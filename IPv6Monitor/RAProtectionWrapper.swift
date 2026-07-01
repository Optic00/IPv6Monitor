import Foundation

enum RAProtectionWrapper {
  static let wrapperPath = "/Library/PrivilegedHelperTools/ipv6monitor-pf"
  static let defaultSniffSeconds = 60

  struct Status: Equatable {
    let active: Bool
    let iface: String
    let pass: Int
    let block: Int
    let defaultRoute: Bool
  }

  struct DetectResult: Equatable {
    let gateways: [String]
    let others: Int
  }

  static func parseStatus(_ text: String) -> Status? {
    guard let data = text.data(using: .utf8),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let active = obj["active"] as? Bool,
      let iface = obj["iface"] as? String,
      let pass = obj["pass"] as? Int,
      let block = obj["block"] as? Int,
      let defaultRoute = obj["default_route"] as? Bool
    else { return nil }
    return Status(active: active, iface: iface, pass: pass, block: block, defaultRoute: defaultRoute)
  }

  static func parseDetect(_ text: String) -> DetectResult? {
    guard let data = text.data(using: .utf8),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let gateways = obj["gateways"] as? [String],
      let others = obj["others"] as? Int
    else { return nil }
    return DetectResult(gateways: gateways, others: others)
  }
}
