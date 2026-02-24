import AppKit
import Combine
import Network
import SwiftUI
import SystemConfiguration

// MARK: - 1. Datenmodelle

struct NetworkInterface: Identifiable, Hashable {
  let id = UUID()
  let bsdName: String
  let displayName: String
  var isLikelyPrimary: Bool = false
  var hasIPv6: Bool = false
}

struct PingTarget: Identifiable {
  let id = UUID()
  let name: String
  let ipv4: String
  let ipv6: String
  var isRouter: Bool = false
}

struct PingResult: Identifiable {
  let id = UUID()
  let targetName: String
  var v4Latency: String = "..."
  var v6Latency: String = "..."
  var v4Color: Color = .gray
  var v6Color: Color = .gray
}

enum LogType {
  case info, success, error, warning

  var color: Color {
    switch self {
    case .info: return .primary
    case .success: return .green
    case .error: return .red
    case .warning: return .orange
    }
  }

  var prefix: String {
    switch self {
    case .info: return "ℹ️"
    case .success: return "✅"
    case .error: return "❌"
    case .warning: return "⚠️"
    }
  }
}

struct LogEntry: Identifiable {
  let id = UUID()
  let date: Date
  let message: String
  let type: LogType

  var formattedTime: String {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .medium
    return formatter.string(from: date)
  }

  var fullLogString: String {
    return "[\(formattedTime)] \(type.prefix) \(message)"
  }
}

// MARK: - 2. Logger (ObservableObject)

class Logger: ObservableObject {
  @Published var entries: [LogEntry] = []
  private var logFileURL: URL?
  private let fileQueue = DispatchQueue(label: "org.ipv6monitor.logqueue")

  init() {
    setupLogFile()
  }

  private func setupLogFile() {
    guard
      let libraryDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
    else { return }
    let logDir = libraryDir.appendingPathComponent("Logs/IPv6Monitor")

    do {
      try FileManager.default.createDirectory(
        at: logDir, withIntermediateDirectories: true, attributes: nil)
      logFileURL = logDir.appendingPathComponent("IPv6Monitor.log")
    } catch {
      print("Failed to create log directory: \(error)")
    }
  }

  func add(_ message: String, type: LogType = .info) {
    let entry = LogEntry(date: Date(), message: message, type: type)

    // UI Update
    DispatchQueue.main.async {
      self.entries.append(entry)
      if self.entries.count > 500 { self.entries.removeFirst() }
    }

    // File Write
    fileQueue.async { [weak self] in
      self?.appendToFile(entry.fullLogString)
    }
  }

  private func appendToFile(_ line: String) {
    guard let url = logFileURL, let data = (line + "\n").data(using: .utf8) else { return }

    do {
      if FileManager.default.fileExists(atPath: url.path) {
        let fileHandle = try FileHandle(forWritingTo: url)
        if #available(macOS 10.15.4, *) {
          try fileHandle.seekToEnd()
        } else {
          fileHandle.seekToEndOfFile()
        }
        fileHandle.write(data)
        try fileHandle.close()
      } else {
        try data.write(to: url)
      }
    } catch {
      print("Error writing to log file: \(error)")
    }
  }

  func getCopyString() -> String {
    return entries.map { $0.fullLogString }.joined(separator: "\n")
  }
}

// MARK: - 3. Haupt-App Struktur

@main
struct IPv6MonitorApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  var body: some Scene {
    Settings {
      EmptyView()
    }
  }
}

// MARK: - 4. App Delegate & Logik

class AppDelegate: NSObject, NSApplicationDelegate {
  var statusItem: NSStatusItem?

  var pathMonitor: NWPathMonitor?
  var monitorQueue = DispatchQueue(label: "NetworkMonitorQueue")

  var currentInterface: String?
  var routerIP: String?

  var logger = Logger()

  var settingsWindow: NSWindow?
  var logWindow: NSWindow?
  var connectivityWindow: NSWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    updateIcon(status: .neutral)

    logger.add(NSLocalizedString("App started.", comment: ""), type: .info)

    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(wakeUpCheck),
      name: NSWorkspace.didWakeNotification,
      object: nil
    )

    if let savedInterface = UserDefaults.standard.string(forKey: "selectedInterface") {
      self.currentInterface = savedInterface
      startMonitoring()
    } else {
      openInterfaceSelectionWindow()
    }

    constructMenu()
  }

  // MARK: - Monitoring Logik

  func startMonitoring() {
    pathMonitor?.cancel()

    guard let interface = currentInterface else { return }
    logger.add(
      String(format: NSLocalizedString("Monitoring: %@", comment: ""), interface), type: .info)

    self.routerIP = findRouterIP(interface: interface)
    if let ip = routerIP {
      logger.add(
        String(format: NSLocalizedString("Router IP: %@", comment: ""), ip), type: .success)
    }

    checkRoute(logSuccess: false)

    pathMonitor = NWPathMonitor()
    pathMonitor?.pathUpdateHandler = { [weak self] path in
      DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 2.0) {
        self?.checkRoute(logSuccess: true)
      }
    }
    pathMonitor?.start(queue: monitorQueue)

    constructMenu()
  }

  @objc func wakeUpCheck() {
    logger.add(NSLocalizedString("System Wakeup.", comment: ""), type: .info)
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
      self.checkRoute(logSuccess: true)
    }
  }

  @objc func manualCheck() {
    checkRoute(logSuccess: true)
    openConnectivityWindow()
  }

  // MARK: - API Helpers

  func getSCDynamicStoreValue(key: String) -> [String: Any]? {
    guard let store = SCDynamicStoreCreate(nil, "IPv6Monitor" as CFString, nil, nil) else {
      return nil
    }
    return SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
  }

  func findRouterIP(interface: String) -> String? {
    // 1. API Check: Prüfe aktuelle System-Route via SystemConfiguration
    if let globalDict = getSCDynamicStoreValue(key: "State:/Network/Global/IPv6"),
      let primaryInterface = globalDict["PrimaryInterface"] as? String,
      primaryInterface == interface,
      let router = globalDict["Router"] as? String
    {
      return router
    }

    // 2. Fallback: NDP Suche (Shell), falls keine Default Route existiert,
    // aber ein Router im lokalen Netz bekannt ist (Neighbor Discovery).
    // Dies ist wichtig für den "Reparatur"-Fall.
    let ndpCmd =
      "ndp -an | awk '$2 == \"\(interface)\" && $1 ~ /^fe80::/ && $NF ~ /R/ { print $1; exit }'"
    let ndpResult = shell(ndpCmd).trimmingCharacters(in: .whitespacesAndNewlines)
    if !ndpResult.isEmpty { return ndpResult }

    return nil
  }

  func findIPv4Router(interface: String) -> String? {
    if let globalDict = getSCDynamicStoreValue(key: "State:/Network/Global/IPv4"),
      let primaryInterface = globalDict["PrimaryInterface"] as? String,
      primaryInterface == interface,
      let router = globalDict["Router"] as? String
    {
      return router
    }

    let cmd = "ipconfig getoption \(interface) router"
    let res = shell(cmd).trimmingCharacters(in: .whitespacesAndNewlines)
    return res.isEmpty ? nil : res
  }

  func checkRoute(logSuccess: Bool) {
    guard let interface = currentInterface else { return }

    if routerIP == nil {
      routerIP = findRouterIP(interface: interface)
    }

    guard let rIP = routerIP else { return }
    let cleanIP = rIP.trimmingCharacters(in: .whitespacesAndNewlines)

    // 1. Kernel-Check: Does the route actually exist in the routing table?
    // "route -n get -inet6 default" returns 0 if found, 1 if not ("not in table").
    // We also verify if it matches our expected IP/Interface.
    let checkCommand = "route -n get -inet6 default 2>/dev/null | grep -q '\(cleanIP)%\(interface)'"
    let exitCode = shellExitCode(checkCommand)

    // 2. Determine Validity
    let routeValid = (exitCode == 0)

    if routeValid {
      updateIcon(status: .ok)
      if logSuccess {
        logger.add(NSLocalizedString("Route check: OK", comment: ""), type: .success)
      }
    } else {
      logger.add(
        NSLocalizedString("❌ Route lost! Starting repair...", comment: ""), type: .error)
      updateIcon(status: .error)
      fixRoute(routerIP: cleanIP, interface: interface)
    }
  }

  func fixRoute(routerIP: String, interface: String) {
    let cleanIP = routerIP.trimmingCharacters(in: .whitespacesAndNewlines)

    // Use 'sudo -n' (non-interactive).
    // Requires the user to add an entry to /etc/sudoers allowing this command without password.
    let command = "/usr/bin/sudo -n /sbin/route -n add -inet6 default \(cleanIP)%\(interface)"

    let exitCode = shellExitCode(command)

    if exitCode == 0 {
      logger.add(NSLocalizedString("✅ Route repaired", comment: ""), type: .success)
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        self.checkRoute(logSuccess: true)
      }
    } else {
      logger.add(
        String(format: NSLocalizedString("⚠️ Repair failed (Code %d).", comment: ""), exitCode),
        type: .error)
      logger.add(NSLocalizedString("ℹ️ See README for sudoers setup.", comment: ""), type: .warning)
    }
  }

  // MARK: - Fenster Management
  func openInterfaceSelectionWindow() {
    if settingsWindow != nil {
      settingsWindow?.makeKeyAndOrderFront(nil)
      return
    }

    let contentView = InterfaceSelectionView { [weak self] selectedBsdName in
      self?.currentInterface = selectedBsdName
      UserDefaults.standard.set(selectedBsdName, forKey: "selectedInterface")
      self?.settingsWindow?.close()
      self?.settingsWindow = nil
      self?.startMonitoring()
    }

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered, defer: false
    )
    window.center()
    window.title = NSLocalizedString("Select Interface", comment: "")
    window.contentView = NSHostingView(rootView: contentView)
    window.isReleasedWhenClosed = false

    let windowDelegate = WindowDelegateHelper { [weak self] in self?.settingsWindow = nil }
    window.delegate = windowDelegate
    objc_setAssociatedObject(window, "WindowDelegate", windowDelegate, .OBJC_ASSOCIATION_RETAIN)

    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    self.settingsWindow = window
  }

  @objc func openLogWindow() {
    if logWindow != nil {
      logWindow?.makeKeyAndOrderFront(nil)
      return
    }

    let contentView = LogView(logger: self.logger)

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.center()
    window.title = NSLocalizedString("Log", comment: "")
    window.contentView = NSHostingView(rootView: contentView)
    window.isReleasedWhenClosed = false

    let windowDelegate = WindowDelegateHelper { [weak self] in self?.logWindow = nil }
    window.delegate = windowDelegate
    objc_setAssociatedObject(window, "WindowDelegate", windowDelegate, .OBJC_ASSOCIATION_RETAIN)

    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    self.logWindow = window
  }

  @objc func openConnectivityWindow() {
    if connectivityWindow != nil { connectivityWindow?.close() }

    let rIP = self.routerIP ?? ""
    let iface = self.currentInterface ?? ""

    // IPv4 Router ermitteln
    let v4Router = findIPv4Router(interface: iface) ?? "-"

    let contentView = ConnectivityView(routerIPv6: rIP, routerIPv4: v4Router, interface: iface)

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 550, height: 400), styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    window.center()
    window.title = NSLocalizedString("Connectivity Check", comment: "")
    window.contentView = NSHostingView(rootView: contentView)
    window.isReleasedWhenClosed = false

    let windowDelegate = WindowDelegateHelper { [weak self] in self?.connectivityWindow = nil }
    window.delegate = windowDelegate
    objc_setAssociatedObject(window, "WindowDelegate", windowDelegate, .OBJC_ASSOCIATION_RETAIN)

    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    self.connectivityWindow = window
  }

  // MARK: - Shell Helpers (Basics)

  func shell(_ command: String) -> String {
    let task = Process()
    let pipe = Pipe()
    let errorPipe = Pipe()

    task.standardOutput = pipe
    task.standardError = errorPipe
    task.launchPath = "/bin/bash"
    task.arguments = ["-c", command]

    do {
      try task.run()
      task.waitUntilExit()
    } catch {
      return ""
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
  }

  func shellExitCode(_ command: String) -> Int32 {
    let task = Process()
    task.launchPath = "/bin/bash"
    task.arguments = ["-c", command]
    try? task.run()
    task.waitUntilExit()
    return task.terminationStatus
  }

  // MARK: - UI Updates

  enum StatusType { case ok, error, neutral }

  func updateIcon(status: StatusType) {
    DispatchQueue.main.async {
      guard let button = self.statusItem?.button else { return }
      let image = NSImage(systemSymbolName: "network", accessibilityDescription: "IPv6 Monitor")

      var color: NSColor
      switch status {
      case .ok: color = .systemGreen
      case .error: color = .systemRed
      case .neutral: color = .secondaryLabelColor
      }

      let config = NSImage.SymbolConfiguration(paletteColors: [color])
      button.image = image?.withSymbolConfiguration(config)
    }
  }

  func constructMenu() {
    DispatchQueue.main.async {
      let menu = NSMenu()

      let interfaceTitle =
        self.currentInterface != nil
        ? String(format: NSLocalizedString("Interface: %@", comment: ""), self.currentInterface!)
        : NSLocalizedString("No Interface", comment: "")
      menu.addItem(NSMenuItem(title: interfaceTitle, action: nil, keyEquivalent: ""))

      if let rIP = self.routerIP {
        menu.addItem(
          withTitle: String(format: NSLocalizedString("Router: %@", comment: ""), rIP), action: nil,
          keyEquivalent: "")
      }

      menu.addItem(NSMenuItem.separator())
      menu.addItem(
        NSMenuItem(
          title: NSLocalizedString("Connectivity Check", comment: ""),
          action: #selector(self.manualCheck), keyEquivalent: "r"))
      menu.addItem(
        NSMenuItem(
          title: NSLocalizedString("Show Log...", comment: ""),
          action: #selector(self.openLogWindow), keyEquivalent: "l"))
      menu.addItem(
        NSMenuItem(
          title: NSLocalizedString("Change Interface...", comment: ""),
          action: #selector(self.changeInterface), keyEquivalent: "i"))

      menu.addItem(NSMenuItem.separator())
      menu.addItem(
        NSMenuItem(
          title: NSLocalizedString("Quit", comment: ""),
          action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

      self.statusItem?.menu = menu
    }
  }

  @objc func changeInterface() { openInterfaceSelectionWindow() }
}

class WindowDelegateHelper: NSObject, NSWindowDelegate {
  let onClose: () -> Void
  init(onClose: @escaping () -> Void) { self.onClose = onClose }
  func windowWillClose(_ notification: Notification) { onClose() }
}

// MARK: - 5. SwiftUI Views

// --- Connectivity Check View ---
struct ConnectivityView: View {
  var routerIPv6: String
  var routerIPv4: String
  var interface: String

  @State private var targets: [PingTarget] = []
  @State private var results: [PingResult] = []

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(NSLocalizedString("Target", comment: "")).frame(width: 120, alignment: .leading).bold()
        Text(NSLocalizedString("IPv4 (ms)", comment: "")).frame(
          maxWidth: .infinity, alignment: .leading
        ).bold()
        Text(NSLocalizedString("IPv6 (ms)", comment: "")).frame(
          maxWidth: .infinity, alignment: .leading
        ).bold()
      }
      .padding()
      .background(Color.gray.opacity(0.1))

      Divider()

      List(results) { res in
        HStack {
          Text(res.targetName).frame(width: 120, alignment: .leading).font(
            .system(.body, design: .monospaced))
          Text(res.v4Latency).frame(maxWidth: .infinity, alignment: .leading).foregroundColor(
            res.v4Color
          ).font(.system(.body, design: .monospaced))
          Text(res.v6Latency).frame(maxWidth: .infinity, alignment: .leading).foregroundColor(
            res.v6Color
          ).font(.system(.body, design: .monospaced))
        }
      }
      .listStyle(.plain)

      Divider()

      HStack {
        Button(NSLocalizedString("Check Again", comment: "")) { runTests() }
        Spacer()
        Text(NSLocalizedString("Timeout: 1s", comment: "")).font(.caption).foregroundColor(
          .secondary)
      }
      .padding()
    }
    .onAppear {
      prepareTargets()
      runTests()
    }
  }

  func prepareTargets() {
    var t = [
      PingTarget(name: "Google DNS", ipv4: "8.8.8.8", ipv6: "2001:4860:4860::8888"),
      PingTarget(name: "Cloudflare", ipv4: "1.1.1.1", ipv6: "2606:4700:4700::1111"),
      PingTarget(name: "Quad9", ipv4: "9.9.9.9", ipv6: "2620:fe::fe"),
      PingTarget(name: "OpenDNS", ipv4: "208.67.222.222", ipv6: "2620:119:35::35"),
    ]

    let cleanRouterIP = routerIPv6.trimmingCharacters(in: .whitespacesAndNewlines)
    let v6Address: String
    if !cleanRouterIP.isEmpty {
      if cleanRouterIP.contains("%") {
        v6Address = cleanRouterIP
      } else {
        v6Address = "\(cleanRouterIP)%\(interface)"
      }
    } else {
      v6Address = "-"
    }

    let routerTarget = PingTarget(
      name: NSLocalizedString("Gateway", comment: ""), ipv4: routerIPv4, ipv6: v6Address,
      isRouter: true)
    t.insert(routerTarget, at: 0)
    self.targets = t
  }

  func runTests() {
    results = targets.map { PingResult(targetName: $0.name) }

    for (index, target) in targets.enumerated() {
      // IPv4
      if target.ipv4 != "-" && !target.ipv4.isEmpty {
        ping(host: target.ipv4, type: .ipv4) { lat in
          DispatchQueue.main.async { updateResult(index: index, v4: lat) }
        }
      } else {
        DispatchQueue.main.async { updateResult(index: index, v4: -2) }
      }

      // IPv6
      if target.ipv6 != "-" && !target.ipv6.isEmpty {
        ping(host: target.ipv6, type: .ipv6) { lat in
          DispatchQueue.main.async { updateResult(index: index, v6: lat) }
        }
      } else {
        DispatchQueue.main.async { updateResult(index: index, v6: -2) }
      }
    }
  }

  func updateResult(index: Int, v4: Double? = nil, v6: Double? = nil) {
    if let val = v4 {
      if val == -2 {
        results[index].v4Latency = "-"
        results[index].v4Color = .secondary
      } else if val < 0 {
        results[index].v4Latency = NSLocalizedString("Timeout", comment: "")
        results[index].v4Color = .red
      } else {
        results[index].v4Latency = String(format: "%.0f", val)
        results[index].v4Color = .green
      }
    }
    if let val = v6 {
      if val == -2 {
        results[index].v6Latency = "-"
        results[index].v6Color = .secondary
      } else if val < 0 {
        results[index].v6Latency = NSLocalizedString("Timeout", comment: "")
        results[index].v6Color = .red
      } else {
        results[index].v6Latency = String(format: "%.0f", val)
        results[index].v6Color = .green
      }
    }
  }

  nonisolated enum PingType: Equatable { case ipv4, ipv6 }

  nonisolated func ping(host: String, type: PingType, completion: @escaping (Double) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
      let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)

      // WICHTIG: Strikte Trennung.
      // IPv4 -> /sbin/ping
      // IPv6 -> /sbin/ping6 (robuster bei Link-Local). Fallback: /sbin/ping -6
      var binary = (type == .ipv6) ? "/sbin/ping6" : "/sbin/ping"
      var args: [String] = ["-c", "1", "-n", cleanHost]

      if type == .ipv6 {
        if !FileManager.default.fileExists(atPath: binary) {
          // Fallback falls ping6 nicht existiert: ping -6
          binary = "/sbin/ping"
          args = ["-6", "-c", "1", "-n", cleanHost]
        }
      }

      runPingCommand(
        binary: binary, arguments: args, isIPv6: (type == .ipv6), completion: completion)
    }
  }

  nonisolated func runPingCommand(
    binary: String, arguments: [String], isIPv6: Bool, completion: @escaping (Double) -> Void
  ) {
    let task = Process()
    let stdout = Pipe()
    let stderr = Pipe()

    task.standardOutput = stdout
    task.standardError = stderr
    task.launchPath = binary
    // Verwenden die vorbereiteten Argumente (ohne -W). Timeout manuell.
    task.arguments = arguments

    let timeoutSeconds: TimeInterval = 1.5
    let start = Date()

    var terminated = false

    let terminationObserver = NotificationCenter.default.addObserver(
      forName: Process.didTerminateNotification, object: task, queue: nil
    ) { _ in
      terminated = true
    }

    func finish(with value: Double) {
      NotificationCenter.default.removeObserver(terminationObserver)
      completion(value)
    }

    DispatchQueue.global().async {
      do {
        try task.run()
      } catch {
        finish(with: -1.0)
        return
      }

      while !terminated {
        if Date().timeIntervalSince(start) > timeoutSeconds {
          task.terminate()
          break
        }
        usleep(20_000)  // 20ms
      }

      task.waitUntilExit()

      let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
      _ = stderr.fileHandleForReading.readDataToEndOfFile()
      let output = String(data: outputData, encoding: .utf8) ?? ""

      if task.terminationStatus == 0 {
        // Versuche verschiedene Patterns für die Zeit
        if let range = output.range(of: #"time=([0-9.]+)"#, options: .regularExpression) {
          let timeStr = String(output[range]).replacingOccurrences(of: "time=", with: "")
          if let time = Double(timeStr) {
            finish(with: time)
            return
          }
        }
        // Manche Varianten geben z.B. "round-trip min/avg/max/stddev = 9.902/9.902/9.902/0.000 ms"
        if output.range(of: #"avg/max/"#, options: .regularExpression) != nil {
          // Fallback: parse die erste gefundene Zahl in ms
          if let numRange = output.range(
            of: #"([0-9]+\.[0-9]+|[0-9]+) ms"#, options: .regularExpression)
          {
            let numStr = String(output[numRange]).replacingOccurrences(of: " ms", with: "")
            if let time = Double(numStr) {
              finish(with: time)
              return
            }
          }
        }
        // Erfolg, aber Zeit nicht parsbar
        finish(with: 0.0)
      } else {
        // Timeout oder Fehler
        finish(with: -1.0)
      }
    }
  }
}

// --- Log View ---
struct LogView: View {
  @ObservedObject var logger: Logger

  var body: some View {
    VStack(spacing: 0) {
      ScrollViewReader { proxy in
        List(logger.entries) { entry in
          HStack(alignment: .top) {
            Text(entry.formattedTime).font(.system(.caption, design: .monospaced)).foregroundColor(
              .secondary)
            Text(entry.message).foregroundColor(entry.type.color).font(
              .system(.body, design: .monospaced))
            Spacer()
          }
          .id(entry.id)
        }
        .onChange(of: logger.entries.count) {
          if let last = logger.entries.last {
            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
          }
        }
      }
      Divider()
      HStack {
        Text(String(format: NSLocalizedString("%d Entries", comment: ""), logger.entries.count))
          .font(.caption).foregroundColor(.secondary)
        Spacer()
        Button(action: {
          let pasteboard = NSPasteboard.general
          pasteboard.clearContents()
          pasteboard.setString(logger.getCopyString(), forType: .string)
        }) { Label(NSLocalizedString("Copy Log", comment: ""), systemImage: "doc.on.doc") }
      }
      .padding().background(Color(NSColor.windowBackgroundColor))
    }
    .frame(minWidth: 400, minHeight: 300)
  }
}

// --- Interface Selection View ---
struct InterfaceSelectionView: View {
  var onSelect: (String) -> Void
  @State private var interfaces: [NetworkInterface] = []
  @State private var isLoading = true

  var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: 8) {
        Image(systemName: "network.badge.shield.half.filled").font(.system(size: 40))
          .foregroundColor(.blue).padding(.top, 20)
        Text(NSLocalizedString("Interface Monitoring", comment: "")).font(.title2).bold()
        Text(NSLocalizedString("Select the interface with internet connection.", comment: "")).font(
          .caption
        ).foregroundColor(.secondary)
      }
      .padding(.bottom, 20)
      Divider()
      if isLoading {
        Spacer()
        ProgressView(NSLocalizedString("Analyzing network...", comment: ""))
        Spacer()
      } else {
        List(interfaces) { iface in
          HStack(alignment: .center) {
            Image(systemName: iconName(for: iface.displayName)).font(.title2).frame(width: 30)
              .foregroundColor(iface.isLikelyPrimary ? .blue : .gray)
            VStack(alignment: .leading, spacing: 2) {
              HStack {
                Text(iface.displayName).font(.headline)
                if iface.isLikelyPrimary {
                  Text(NSLocalizedString("ACTIVE", comment: "")).font(
                    .system(size: 10, weight: .bold)
                  ).padding(.horizontal, 6).padding(.vertical, 2).background(
                    Color.green.opacity(0.8)
                  ).foregroundColor(.white).cornerRadius(8)
                }
                if iface.hasIPv6 {
                  Text("IPv6").font(.system(size: 10, weight: .bold)).padding(.horizontal, 6)
                    .padding(.vertical, 2).background(Color.blue.opacity(0.2)).foregroundColor(
                      .blue
                    ).cornerRadius(8)
                }
              }
              Text("BSD: \(iface.bsdName)").font(.caption).foregroundColor(.gray)
            }
            Spacer()
            Button(NSLocalizedString("Select", comment: "")) { onSelect(iface.bsdName) }
              .buttonStyle(.borderedProminent).tint(
                iface.isLikelyPrimary ? .blue : .gray.opacity(0.5))
          }
          .padding(.vertical, 4)
        }
        .listStyle(.inset)
      }
    }
    .frame(minWidth: 500, minHeight: 450)
    .onAppear(perform: loadInterfaces)
  }

  func iconName(for name: String) -> String {
    let lower = name.lowercased()
    if lower.contains("wi-fi") || lower.contains("wlan") { return "wifi" }
    if lower.contains("ethernet") || lower.contains("lan") { return "cable.connector" }
    if lower.contains("thunderbolt") { return "bolt.fill" }
    return "network"
  }

  func loadInterfaces() {
    DispatchQueue.global(qos: .userInitiated).async {
      var result: [NetworkInterface] = []

      // 1. Hole Default Route Interface via API
      var defaultRouteInterface = ""
      if let store = SCDynamicStoreCreate(nil, "IPv6Monitor" as CFString, nil, nil),
        let globalDict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv6" as CFString)
          as? [String: Any],
        let primary = globalDict["PrimaryInterface"] as? String
      {
        defaultRouteInterface = primary
      }

      if let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
        for interface in interfaces {
          if let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
            let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
          {

            // 2. Prüfe IPv6 via API
            var hasIPv6 = false
            var hasGlobalIPv6 = false

            if let store = SCDynamicStoreCreate(nil, "IPv6Monitor" as CFString, nil, nil),
              let dict = SCDynamicStoreCopyValue(
                store, "State:/Network/Interface/\(bsd)/IPv6" as CFString) as? [String: Any],
              let addresses = dict["Addresses"] as? [String]
            {

              hasIPv6 = !addresses.isEmpty
              // Check for Global Unicast (startet nicht mit fe80:: und ist nicht ::1)
              for addr in addresses {
                if !addr.starts(with: "fe80") && addr != "::1" {
                  hasGlobalIPv6 = true
                }
              }
            }

            var likelyPrimary = (bsd == defaultRouteInterface)

            // Fallback Heuristik, falls kein Default Route, aber Global IPv6
            if !likelyPrimary && hasGlobalIPv6 {
              // Wenn wir keine Default Route gefunden haben, aber dieses Interface eine echte IPv6 hat
              if defaultRouteInterface.isEmpty {
                likelyPrimary = true
              }
            }

            result.append(
              NetworkInterface(
                bsdName: bsd, displayName: name, isLikelyPrimary: likelyPrimary, hasIPv6: hasIPv6))
          }
        }
      }
      result.sort {
        if $0.isLikelyPrimary && !$1.isLikelyPrimary { return true }
        return false
      }
      DispatchQueue.main.async {
        self.interfaces = result
        self.isLoading = false
      }
    }
  }
}
