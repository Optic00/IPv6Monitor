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

extension RAProtectionWrapper {
  // owner must be uid 0 and neither group- nor other-writable, for the path and every parent.
  static func pathIsSafe(_ path: String) -> Bool {
    let fm = FileManager.default
    // Resolve relative paths to absolute (anchored at cwd), matching bash's `cd ... && pwd` behavior
    var absolutePath = path
    if !path.hasPrefix("/") {
      absolutePath = fm.currentDirectoryPath + "/" + path
    }
    var current = (absolutePath as NSString).standardizingPath
    while true {
      guard let attrs = try? fm.attributesOfItem(atPath: current) else { return false }
      guard let owner = attrs[.ownerAccountID] as? NSNumber, owner.intValue == 0 else { return false }
      guard let perm = attrs[.posixPermissions] as? NSNumber else { return false }
      let mode = perm.intValue
      if mode & 0o002 != 0 { return false }
      if mode & 0o020 != 0 { return false }
      if current == "/" { break }
      let parent = (current as NSString).deletingLastPathComponent
      current = parent.isEmpty ? "/" : parent
    }
    return true
  }
}
