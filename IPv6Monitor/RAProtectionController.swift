// IPv6Monitor/RAProtectionController.swift
import Foundation
import Combine

final class RAProtectionController: ObservableObject {
  enum UIState: Equatable {
    case off
    case preparing
    case armingConfirm(RAProtectionWrapper.DetectResult, needsMultiGatewayConfirmation: Bool)
    case active(RAProtectionWrapper.Status)
    case autoOffNotice(reason: String, redetect: RAProtectionWrapper.DetectResult?)
    case unavailable(reason: String)
  }

  @Published private(set) var isVisible: Bool = false
  @Published private(set) var uiState: UIState = .off

  private let logger: Logger
  let workQueue = DispatchQueue(label: "org.ipv6monitor.raprotection")
  private var armedIface: String?
  private var lastKnownPass: Int = 0
  private var lastPassIncreaseAt: Date = Date()

  private static let everLostRouteKey = "raProtectionEverLostRoute"
  private static let autoArmOnLaunchKey = "raProtectionAutoArmOnLaunch"

  init(logger: Logger) {
    self.logger = logger
  }

  static func markRouteLossEverOccurred() {
    UserDefaults.standard.set(true, forKey: everLostRouteKey)
  }

  var autoArmOnLaunch: Bool {
    get { UserDefaults.standard.bool(forKey: Self.autoArmOnLaunchKey) }
    set { UserDefaults.standard.set(newValue, forKey: Self.autoArmOnLaunchKey) }
  }

  // Whether the risk-profile gate says the feature should be *offered* right now. Views/menus
  // must NOT gate on this alone — see `showsControls` below.
  func refreshVisibility(hasGlobalIPv6: Bool, routerCount: Int) {
    let visible = Self.currentlyVisible(hasGlobalIPv6: hasGlobalIPv6, routerCount: routerCount)
    DispatchQueue.main.async { self.isVisible = visible }
  }

  // Synchronous, side-effect-free version of the same check, for callers that must act on the
  // result immediately (e.g. attemptReArmOnLaunch) instead of racing the async `isVisible` write.
  private static func currentlyVisible(hasGlobalIPv6: Bool, routerCount: Int) -> Bool {
    let hadLoss = UserDefaults.standard.bool(forKey: everLostRouteKey)
    let profile = RAProtectionGating.RiskProfile(
      hasGlobalIPv6: hasGlobalIPv6, routerCount: routerCount, hadPriorRouteLoss: hadLoss)
    return RAProtectionGating.isVisible(profile)
  }

  // Once anything beyond idle is happening (preparing/confirming/active/auto-off), the controls
  // — including the one-click Off — must stay visible even if the risk profile no longer
  // matches (e.g. the filter itself reduced the router count back to 1). Only hide when both
  // off AND the risk profile says "nothing to offer".
  var showsControls: Bool {
    if isVisible { return true }
    if case .off = uiState { return false }
    return true
  }

  func cancelArming() {
    DispatchQueue.main.async { self.uiState = .off }
  }

  func acknowledgeAutoOff() {
    DispatchQueue.main.async { self.uiState = .off }
  }
}

extension RAProtectionController {
  func beginArmingFlow(iface: String) {
    DispatchQueue.main.async { self.uiState = .preparing }
    workQueue.async { [weak self] in
      guard let self else { return }
      let result = RAProtectionWrapper.run(subcommand: "detect", arguments: [iface])
      guard result.exitCode == 0, let detect = RAProtectionWrapper.parseDetect(result.stdout) else {
        DispatchQueue.main.async {
          self.uiState = .unavailable(
            reason: result.stderr.isEmpty ? NSLocalizedString("Detection failed.", comment: "") : result.stderr)
        }
        return
      }
      let precheck = RAProtectionGating.ArmingPrecheck(
        gatewayFreshnessSeconds: detect.gateways.isEmpty ? nil : Double(RAProtectionWrapper.defaultSniffSeconds),
        otherSendersCount: detect.others,
        gatewayCount: detect.gateways.count)
      let decision = RAProtectionGating.evaluateArming(precheck)
      DispatchQueue.main.async {
        switch decision {
        case .allowed:
          self.uiState = .armingConfirm(detect, needsMultiGatewayConfirmation: false)
        case .allowedNeedsMultiGatewayConfirmation:
          self.uiState = .armingConfirm(detect, needsMultiGatewayConfirmation: true)
        case .refusedNoFreshGateway:
          self.uiState = .unavailable(
            reason: NSLocalizedString("No gateway RA seen — nothing to whitelist.", comment: ""))
        case .refusedNoOtherSenders:
          self.uiState = .unavailable(
            reason: NSLocalizedString("No other RA senders currently seen — nothing to block.", comment: ""))
        }
      }
    }
  }

  func confirmArm(iface: String, acknowledgedMultiGateway: Bool) {
    guard case let .armingConfirm(detect, needsConfirm) = uiState else { return }
    if needsConfirm && !acknowledgedMultiGateway { return }
    // `evaluateArming` only reaches `.armingConfirm` when `gatewayFreshnessSeconds != nil`,
    // which is only set when `detect.gateways` is non-empty — so this is always populated here.
    guard let gateway = detect.gateways.first else { return }
    DispatchQueue.main.async { self.uiState = .preparing }
    workQueue.async { [weak self] in
      guard let self else { return }
      // Ping the SAME target before and after (per the design spec) — comparing against
      // `on`'s `default_route` field would mix two different signals (route-table presence
      // vs. actual reachability) and could miss a gateway that's unreachable despite a route.
      let preOk = self.pingGateway(gateway, iface: iface)
      let result = RAProtectionWrapper.run(subcommand: "on", arguments: [iface])
      guard result.exitCode == 0, let status = RAProtectionWrapper.parseStatus(result.stdout) else {
        DispatchQueue.main.async {
          self.uiState = .unavailable(
            reason: result.stderr.isEmpty ? NSLocalizedString("Arming failed.", comment: "") : result.stderr)
        }
        return
      }
      let postOk = self.pingGateway(gateway, iface: iface)
      if preOk && !postOk {
        _ = RAProtectionWrapper.run(subcommand: "off")
        DispatchQueue.main.async {
          self.logger.add("⚠️ RA protection auto-off: gateway unreachable right after arming.", type: .error)
          self.uiState = .autoOffNotice(
            reason: NSLocalizedString(
              "The gateway became unreachable immediately after arming.", comment: ""),
            redetect: nil)
        }
        return
      }
      self.armedIface = iface
      self.lastKnownPass = status.pass
      self.lastPassIncreaseAt = Date()
      DispatchQueue.main.async {
        self.logger.add(
          String(format: NSLocalizedString("RA protection armed on %@", comment: ""), iface), type: .success)
        self.uiState = .active(status)
      }
    }
  }

  // Manual-timeout ping, mirroring ConnectivityView.runPingCommand's approach (no reliance on
  // a `-t`/`-W` timeout flag whose exact semantics differ between ping/ping6 on macOS).
  func pingGateway(_ gateway: String, iface: String, timeout: TimeInterval = 2.0) -> Bool {
    let target = gateway.contains("%") ? gateway : "\(gateway)%\(iface)"
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/sbin/ping6")
    task.arguments = ["-c", "1", "-n", target]
    task.standardOutput = Pipe()
    task.standardError = Pipe()
    do {
      try task.run()
    } catch {
      return false
    }
    let start = Date()
    while task.isRunning {
      if Date().timeIntervalSince(start) > timeout {
        task.terminate()
        break
      }
      usleep(20_000)
    }
    task.waitUntilExit()
    return task.terminationStatus == 0
  }
}

extension RAProtectionController {
  func disarm() {
    workQueue.async { [weak self] in
      guard let self else { return }
      let result = RAProtectionWrapper.run(subcommand: "off")
      self.armedIface = nil
      DispatchQueue.main.async {
        if result.exitCode == 0 {
          self.logger.add(NSLocalizedString("RA protection turned off.", comment: ""), type: .info)
        }
        self.uiState = .off
      }
    }
  }

  // Called from the app's existing poll loop (AppDelegate.performRouteCheck) whenever we're
  // armed; a no-op otherwise so this never fires wrapper calls while off. `armedIface` is only
  // ever read/written on `workQueue` (here, in confirmArm, and in disarm) — the guard used to
  // read it on the caller's queue instead, which was a cross-queue data race.
  func pollHealth(currentInterface: String) {
    workQueue.async { [weak self] in
      guard let self, let armed = self.armedIface else { return }
      let result = RAProtectionWrapper.run(subcommand: "status")
      guard result.exitCode == 0, let status = RAProtectionWrapper.parseStatus(result.stdout) else { return }
      if status.pass > self.lastKnownPass {
        self.lastKnownPass = status.pass
        self.lastPassIncreaseAt = Date()
      }
      let verdict = RAProtectionHealth.evaluate(
        active: status.active,
        ifaceMatches: status.iface == currentInterface && currentInterface == armed,
        now: Date(),
        lastPassIncreaseAt: self.lastPassIncreaseAt)
      guard verdict != .ok else {
        DispatchQueue.main.async { self.uiState = .active(status) }
        return
      }
      _ = RAProtectionWrapper.run(subcommand: "off")
      self.armedIface = nil
      let detectResult = RAProtectionWrapper.run(subcommand: "detect", arguments: [currentInterface])
      let redetect = RAProtectionWrapper.parseDetect(detectResult.stdout)
      let reason: String
      switch verdict {
      case .autoOffAnchorGone:
        reason = NSLocalizedString("The firewall rule was removed externally.", comment: "")
      case .autoOffInterfaceChanged:
        reason = NSLocalizedString("The network interface changed.", comment: "")
      case .autoOffPassStalled:
        reason = NSLocalizedString("Gateway RAs stopped arriving — the gateway may have changed.", comment: "")
      case .ok:
        reason = ""
      }
      DispatchQueue.main.async {
        self.logger.add("⚠️ RA protection auto-off: \(reason)", type: .error)
        self.uiState = .autoOffNotice(reason: reason, redetect: redetect)
      }
    }
  }

  // "re-arm on launch", honored only after re-validation (spec: fresh gateway RA + risk
  // profile still present + clean detection). If re-detection needs a human decision (no
  // fresh gateway, no other senders, or multiple gateways), we surface the normal confirm/
  // unavailable state instead of silently arming.
  func attemptReArmOnLaunch(iface: String, hasGlobalIPv6: Bool, routerCount: Int) {
    guard autoArmOnLaunch else { return }
    // Use the synchronous check here, not `refreshVisibility` — that writes `isVisible` via
    // `DispatchQueue.main.async`, so reading it right back on this call site would race the
    // write and could see the stale value from before this launch.
    guard Self.currentlyVisible(hasGlobalIPv6: hasGlobalIPv6, routerCount: routerCount) else { return }
    DispatchQueue.main.async {
      self.isVisible = true
      self.uiState = .preparing
    }
    workQueue.async { [weak self] in
      guard let self else { return }
      let result = RAProtectionWrapper.run(subcommand: "detect", arguments: [iface])
      guard result.exitCode == 0, let detect = RAProtectionWrapper.parseDetect(result.stdout) else {
        DispatchQueue.main.async { self.uiState = .off }
        return
      }
      let precheck = RAProtectionGating.ArmingPrecheck(
        gatewayFreshnessSeconds: detect.gateways.isEmpty ? nil : Double(RAProtectionWrapper.defaultSniffSeconds),
        otherSendersCount: detect.others,
        gatewayCount: detect.gateways.count)
      let decision = RAProtectionGating.evaluateArming(precheck)
      switch decision {
      case .allowed:
        DispatchQueue.main.async { self.confirmArm(iface: iface, acknowledgedMultiGateway: false) }
      case .allowedNeedsMultiGatewayConfirmation:
        // Multiple gateways always need an explicit human confirmation (per the design spec's
        // edge case) — auto-re-arm-on-launch must not skip that, so surface the sheet instead.
        DispatchQueue.main.async {
          self.uiState = .armingConfirm(detect, needsMultiGatewayConfirmation: true)
        }
      case .refusedNoFreshGateway, .refusedNoOtherSenders:
        // Re-validation failed — per the spec, "only after re-validation" means we do NOT
        // force any arming UI on the user at launch; fall back to idle and let them use
        // "Prepare..." manually. (The earlier `guard decision == .allowed` shortcut here used
        // to route BOTH refusal cases into `.armingConfirm(..., needsMultiGatewayConfirmation:
        // false)`, which left an enabled "Arm" button for a precheck that said to refuse.)
        DispatchQueue.main.async { self.uiState = .off }
      }
    }
  }
}
