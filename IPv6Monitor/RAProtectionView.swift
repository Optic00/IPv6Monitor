// IPv6Monitor/RAProtectionView.swift
import SwiftUI

struct RAProtectionPanel: View {
  @ObservedObject var controller: RAProtectionController
  var interface: String

  var body: some View {
    // `showsControls`, not `isVisible` — an active/preparing/confirming/auto-off filter must
    // stay visible (with its one-click Off) even if the risk profile no longer matches, e.g.
    // because the filter itself reduced the router count back to 1.
    if controller.showsControls {
      VStack(alignment: .leading, spacing: 8) {
        header
        content
      }
      .padding()
      .background(Color.blue.opacity(0.06))
      .cornerRadius(8)
    }
  }

  private var header: some View {
    HStack {
      Image(systemName: "shield.lefthalf.filled")
      Text(NSLocalizedString("RA Protection (advanced)", comment: "")).bold()
      Spacer()
    }
  }

  @ViewBuilder
  private var content: some View {
    switch controller.uiState {
    case .off:
      Button(NSLocalizedString("Prepare...", comment: "")) {
        controller.beginArmingFlow(iface: interface)
      }
    case .preparing:
      RAProtectionPreparingView()
    case .armingConfirm(let detect, let needsConfirm):
      RAProtectionConfirmSheet(
        detect: detect, needsMultiGatewayConfirmation: needsConfirm, interface: interface,
        onConfirm: { ack in controller.confirmArm(iface: interface, acknowledgedMultiGateway: ack) },
        onCancel: { controller.cancelArming() })
    case .active(let status):
      VStack(alignment: .leading, spacing: 4) {
        Text(
          String(
            format: NSLocalizedString("Active on %@ — passed: %d, blocked: %d", comment: ""),
            status.iface, status.pass, status.block))
        Button(NSLocalizedString("Turn off", comment: ""), role: .destructive) { controller.disarm() }
        Toggle(NSLocalizedString("Re-arm automatically on launch", comment: ""), isOn: $controller.autoArmOnLaunch)
          .font(.caption)
      }
    case .autoOffNotice(let reason, _):
      VStack(alignment: .leading, spacing: 4) {
        Text("⚠️ \(reason)").foregroundColor(.orange)
        Button(NSLocalizedString("OK", comment: "")) { controller.acknowledgeAutoOff() }
      }
    case .unavailable(let reason):
      VStack(alignment: .leading, spacing: 4) {
        Text(reason).font(.caption).foregroundColor(.secondary)
        Button(NSLocalizedString("Try again", comment: "")) {
          controller.beginArmingFlow(iface: interface)
        }
      }
    }
  }
}

// Live progress bar for the ~60s wrapper sniff window. `@State private var start` is only
// (re-)initialized when this view's identity is (re-)created — i.e. fresh each time `.preparing`
// is entered — not on every body re-evaluation, so the elapsed time is accurate across renders.
private struct RAProtectionPreparingView: View {
  @State private var start = Date()
  private let duration: TimeInterval = 60

  var body: some View {
    TimelineView(.periodic(from: start, by: 1)) { context in
      let elapsed = min(context.date.timeIntervalSince(start), duration)
      VStack(alignment: .leading, spacing: 4) {
        ProgressView(value: elapsed, total: duration)
        Text(
          String(
            format: NSLocalizedString("Checking network... (%ds of %ds)", comment: ""),
            Int(elapsed), Int(duration))
        )
        .font(.caption).foregroundColor(.secondary)
      }
    }
  }
}

struct RAProtectionConfirmSheet: View {
  var detect: RAProtectionWrapper.DetectResult
  var needsMultiGatewayConfirmation: Bool
  var interface: String
  var onConfirm: (Bool) -> Void
  var onCancel: () -> Void

  @State private var acknowledgedMultiGateway = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(
        NSLocalizedString(
          "Blocks incoming IPv6 Router Advertisements on this interface except from the gateway. May affect Thread/Matter/ULA routes this Mac learns. Applies to this interface only. Reboot or Off removes it.",
          comment: "")
      ).font(.caption)
      Text(String(format: NSLocalizedString("Interface: %@", comment: ""), interface))
      Text(
        String(
          format: NSLocalizedString("Detected gateway(s): %@", comment: ""),
          detect.gateways.joined(separator: ", ")))
      Text(String(format: NSLocalizedString("Other RA senders currently seen: %d", comment: ""), detect.others))
      Text(NSLocalizedString("Detection basis: gateway RA seen during this check (within the last ~60s).", comment: ""))
        .font(.caption).foregroundColor(.secondary)
      if needsMultiGatewayConfirmation {
        Toggle(
          NSLocalizedString("I confirm all listed addresses are legitimate gateways.", comment: ""),
          isOn: $acknowledgedMultiGateway)
      }
      HStack {
        Button(NSLocalizedString("Cancel", comment: "")) { onCancel() }
        Spacer()
        Button(NSLocalizedString("Arm", comment: "")) { onConfirm(acknowledgedMultiGateway) }
          .disabled(needsMultiGatewayConfirmation && !acknowledgedMultiGateway)
          .buttonStyle(.borderedProminent)
      }
    }
    .padding()
  }
}
