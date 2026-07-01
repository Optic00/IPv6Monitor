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
