// Scripts/tests/test-ra-protection-wrapper-json.swift
import Foundation
var failures = 0
func check<T: Equatable>(_ desc: String, _ expected: T, _ actual: T) {
  if expected == actual { print("ok - \(desc)") } else { print("FAIL - \(desc): expected [\(expected)] got [\(actual)]"); failures += 1 }
}

@main struct Tests {
  static func main() {
    let status = RAProtectionWrapper.parseStatus(
      #"{"active":true,"iface":"en10","pass":9313,"block":8678,"default_route":true}"#)
    check(
      "parses status",
      RAProtectionWrapper.Status(active: true, iface: "en10", pass: 9313, block: 8678, defaultRoute: true),
      status)

    let inactive = RAProtectionWrapper.parseStatus(
      #"{"active":false,"iface":"","pass":0,"block":0,"default_route":false}"#)
    check(
      "parses inactive status",
      RAProtectionWrapper.Status(active: false, iface: "", pass: 0, block: 0, defaultRoute: false),
      inactive)

    check("rejects malformed status", true, RAProtectionWrapper.parseStatus("{}") == nil)

    let detect = RAProtectionWrapper.parseDetect(#"{"gateways":["fe80::1"],"others":2}"#)
    check("parses detect", RAProtectionWrapper.DetectResult(gateways: ["fe80::1"], others: 2), detect)

    let emptyDetect = RAProtectionWrapper.parseDetect(#"{"gateways":[],"others":0}"#)
    check("parses empty-gateway detect", RAProtectionWrapper.DetectResult(gateways: [], others: 0), emptyDetect)

    check("rejects malformed detect", true, RAProtectionWrapper.parseDetect("not json") == nil)

    exit(Int32(failures))
  }
}
