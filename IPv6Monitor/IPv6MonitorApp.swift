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
  // Irgendeine IPv6-Adresse (inkl. Link-Local) – nur intern verwendet.
  var hasIPv6: Bool = false
  // Echte Global-Unicast-IPv6 (nicht fe80::/::1) – Grundlage fürs „IPv6"-Badge.
  var hasGlobalIPv6: Bool = false

  // Trägt die Default-Route UND hat echtes IPv6 → das ist das Interface, das man überwachen will.
  var isRecommended: Bool { isLikelyPrimary && hasGlobalIPv6 }
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

enum LogType: CaseIterable, Identifiable, Hashable {
  case info, success, error, warning

  var id: Self { self }

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

  // Lokalisierter Name für das Filter-Menü im Log-Fenster.
  var displayName: String {
    switch self {
    case .info: return NSLocalizedString("Info", comment: "")
    case .success: return NSLocalizedString("Success", comment: "")
    case .error: return NSLocalizedString("Error", comment: "")
    case .warning: return NSLocalizedString("Warning", comment: "")
    }
  }
}

struct LogEntry: Identifiable {
  let id = UUID()
  let date: Date
  let message: String
  let type: LogType
  // Routine-Heartbeat (wiederkehrende „Route Prüfung: OK"). Wird vom
  // „nur Ereignisse"-Filter im Log-Fenster ausgeblendet.
  var isHeartbeat: Bool = false

  // Kurzform nur für die UI-Anzeige im Log-Fenster.
  var formattedTime: String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
  }

  // Kalendertag (auf Mitternacht normiert) – Schlüssel für die Datums-Trenner im Log-Fenster.
  var dayStart: Date {
    Calendar.current.startOfDay(for: date)
  }

  // Lokalisiertes, ausgeschriebenes Datum für die Trennzeile bei Tageswechsel.
  var displayDate: String {
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    formatter.dateStyle = .full
    formatter.timeStyle = .none
    return formatter.string(from: date)
  }

  // Vollständiger Stempel (Datum + Zeit + Zeitzonen-Offset) für die Logdatei.
  // Wichtig für einen über Tage sporadischen Bug: Apple braucht Datum & Zeitzone.
  var fullTimestamp: String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
    return formatter.string(from: date)
  }

  var fullLogString: String {
    return "[\(fullTimestamp)] \(type.prefix) \(message)"
  }
}

// MARK: - 2. Logger (ObservableObject)

class Logger: ObservableObject {
  @Published var entries: [LogEntry] = []
  private var logFileURL: URL?
  // Verzeichnis, in dem Log + Forensik-Snapshots liegen (~/Library/Logs/IPv6Monitor).
  private(set) var logDirectoryURL: URL?
  private let fileQueue = DispatchQueue(label: "org.ipv6monitor.logqueue")

  // Logrotation: bei Überschreitung rollt die Datei zu .1 .. .N.
  // Da im Normalbetrieb nur wenig geloggt wird (nur Statuswechsel/Events), decken
  // 5 MB × 6 Dateien problemlos viele Wochen bis Monate ab.
  private let maxLogBytes: UInt64 = 5_000_000
  private let maxLogBackups = 5

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
      logDirectoryURL = logDir
      logFileURL = logDir.appendingPathComponent("IPv6Monitor.log")
    } catch {
      print("Failed to create log directory: \(error)")
    }
  }

  func add(_ message: String, type: LogType = .info, isHeartbeat: Bool = false) {
    let entry = LogEntry(date: Date(), message: message, type: type, isHeartbeat: isHeartbeat)

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

    rotateIfNeeded()

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

  // Rollt die Logdatei, sobald sie maxLogBytes überschreitet:
  // .5 wird gelöscht, .4->.5, ..., .1->.2, aktuelle Datei -> .1.
  // Läuft auf der fileQueue (serialisiert), daher keine zusätzliche Sperre nötig.
  private func rotateIfNeeded() {
    guard let url = logFileURL else { return }
    let fm = FileManager.default
    let attrs = try? fm.attributesOfItem(atPath: url.path)
    let size = (attrs?[.size] as? UInt64) ?? 0
    guard size > maxLogBytes else { return }

    let dir = url.deletingLastPathComponent()
    let base = url.lastPathComponent

    try? fm.removeItem(at: dir.appendingPathComponent("\(base).\(maxLogBackups)"))
    var i = maxLogBackups - 1
    while i >= 1 {
      let src = dir.appendingPathComponent("\(base).\(i)")
      let dst = dir.appendingPathComponent("\(base).\(i + 1)")
      if fm.fileExists(atPath: src.path) { try? fm.moveItem(at: src, to: dst) }
      i -= 1
    }
    try? fm.moveItem(at: url, to: dir.appendingPathComponent("\(base).1"))
    // Neue (leere) aktuelle Datei wird beim nächsten Schreiben angelegt.
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

  lazy var raProtection: RAProtectionController = RAProtectionController(logger: self.logger)
  private var raProtectionCancellable: AnyCancellable?
  private var raProtectionHealthTimer: Timer?

  // AP3b: Single-Flight. Alle Route-Checks/Reparaturen laufen seriell auf dieser Queue,
  // damit sich Pfad-Events, Wakeup- und manuelle Checks nicht überlappen
  // (sonst doppelte `route add`s, doppelte Snapshots, unleserliche Logs).
  let repairQueue = DispatchQueue(label: "org.ipv6monitor.repairqueue")

  // AP4: Status nur bei Wechsel loggen (kein Spam bei jedem Pfad-Event).
  // nil = noch unbekannt.
  private var lastRouteValid: Bool?
  // AP2/AP4: genau ein Snapshot pro Ausfall-Episode.
  private var outageSnapshotTaken = false
  // AP3: NWPath-Kontext nur bei Änderung loggen.
  private var lastPathDescription: String?
  // Router-Census nur bei Änderung loggen.
  private var lastCensusSummary: String?

  var settingsWindow: NSWindow?
  var logWindow: NSWindow?
  var connectivityWindow: NSWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    updateIcon(status: .neutral)

    logger.add(NSLocalizedString("App started.", comment: ""), type: .info)
    logger.add(
      String(
        format: NSLocalizedString("macOS: %@", comment: ""),
        ProcessInfo.processInfo.operatingSystemVersionString), type: .info)

    // Alte Forensik-Snapshots und Boot-Baselines aufräumen (über Wochen reichlich, aber nicht unbegrenzt).
    pruneSnapshots(keep: 100, prefix: "snapshot-")
    pruneSnapshots(keep: 100, prefix: "startup-")

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

    raProtectionCancellable = raProtection.objectWillChange.sink { [weak self] _ in
      DispatchQueue.main.async { self?.constructMenu() }
    }

    // pollHealth is otherwise only driven by NWPath events/wake/manual checks, which may not
    // fire often enough to catch a silent gateway-RA stall before the route itself dies (the
    // exact failure this health check exists to catch ahead of time). Poll it independently.
    raProtectionHealthTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) {
      [weak self] _ in
      guard let self, let interface = self.currentInterface else { return }
      self.raProtection.pollHealth(currentInterface: interface)
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

    // Baseline: wie viele IPv6-Router sehen wir aktuell im Netz?
    logCensusIfChanged(interface: interface, force: true)

    // AP7: vollständige Boot-Baseline (RA@boot-Zeile + startup-Snapshot) im Hintergrund festhalten.
    captureStartupBaseline(interface: interface)

    checkRoute(logSuccess: false)

    raProtection.reconcileOrReArmOnLaunch(
      iface: interface,
      hasGlobalIPv6: hasGlobalIPv6(interface: interface),
      routerCount: ipv6RouterCensus(interface: interface).total)

    pathMonitor = NWPathMonitor()
    pathMonitor?.pathUpdateHandler = { [weak self] path in
      self?.logPathChange(path)
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
      self.checkRoute(logSuccess: false)
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

  // Gibt die Router-Adresse IMMER ohne Scope (`%ifX`) zurück.
  // Das Anhängen des Scopes übernimmt `scopedAddress` an der Verwendungsstelle.
  func findRouterIP(interface: String) -> String? {
    // 1. API Check: Prüfe aktuelle System-Route via SystemConfiguration.
    // Der SC-`Router`-Wert kommt ohne Scope (verifiziert: "fe80::962a:...").
    if let globalDict = getSCDynamicStoreValue(key: "State:/Network/Global/IPv6"),
      let primaryInterface = globalDict["PrimaryInterface"] as? String,
      primaryInterface == interface,
      let router = globalDict["Router"] as? String
    {
      return stripScope(router.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // 2. Fallback: NDP Neighbor Cache, falls keine Default Route existiert,
    // aber ein Router im lokalen Netz bekannt ist. Wichtig für den "Reparatur"-Fall.
    return findRouterViaNDP(interface: interface)
  }

  // AP0-Fix: korrektes Parsen von `ndp -an`.
  // Spalten: Neighbor | Linklayer Address | Netif | Expire | St | Flgs | Prbs
  // (Bug vorher: `$2 == interface`, aber $2 ist die MAC-Adresse; Netif ist $3.
  //  Außerdem steht das Router-Flag "R" in der Flgs-Spalte (Index 5), nicht im
  //  State (Index 4) — sonst falsch-positiv bei State=R/REACHABLE.)
  func findRouterViaNDP(interface: String) -> String? {
    let output = shell("/usr/sbin/ndp -an")
    var globalFallback: String? = nil

    for rawLine in output.split(separator: "\n") {
      let cols = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
      // Mindestens bis zur Flgs-Spalte (Index 5) müssen Felder vorhanden sein.
      guard cols.count >= 6 else { continue }
      guard cols[2] == interface else { continue }

      // Router-Flag "R" nur in den Flag-Feldern ab Index 5 suchen (State bei 4 ausgeschlossen).
      let isRouter = cols[5...].contains { $0.contains("R") }
      guard isRouter else { continue }

      let bare = stripScope(cols[0])
      // Link-Local-Router bevorzugen (stabiler als globale Adresse für die Default-Route).
      if bare.hasPrefix("fe80") {
        return bare
      }
      if globalFallback == nil { globalFallback = bare }
    }
    return globalFallback
  }

  // Entfernt einen evtl. vorhandenen Scope ("...%en10") -> verhindert "...%en10%en10".
  func stripScope(_ address: String) -> String {
    if let idx = address.firstIndex(of: "%") { return String(address[..<idx]) }
    return address
  }

  // Baut die scope-behaftete Adresse robust, unabhängig davon, ob `ip` schon einen Scope trägt.
  func scopedAddress(_ ip: String, interface: String) -> String {
    let bare = stripScope(ip.trimmingCharacters(in: .whitespacesAndNewlines))
    return "\(bare)%\(interface)"
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

  // Same check as InterfaceSelectionView.loadInterfaces(), but for the currently monitored
  // interface at runtime (used to gate RA-protection visibility).
  func hasGlobalIPv6(interface: String) -> Bool {
    guard let store = SCDynamicStoreCreate(nil, "IPv6Monitor" as CFString, nil, nil),
      let dict = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(interface)/IPv6" as CFString)
        as? [String: Any],
      let addresses = dict["Addresses"] as? [String]
    else { return false }
    return addresses.contains { !$0.starts(with: "fe80") && $0 != "::1" }
  }

  // Öffentlicher Einstieg: serialisiert jeden Check/Repair auf der Repair-Queue (AP3b).
  // logSuccess == true  -> "Route check: OK" immer loggen (manueller Check).
  // logSuccess == false -> nur bei Statuswechsel loggen (Pfad-/Wakeup-Events, kein Spam).
  func checkRoute(logSuccess: Bool) {
    repairQueue.async { [weak self] in
      self?.performRouteCheck(logSuccess: logSuccess)
    }
  }

  private func performRouteCheck(logSuccess: Bool) {
    guard let interface = currentInterface else { return }

    if routerIP == nil {
      routerIP = findRouterIP(interface: interface)
    }
    guard let rIP = routerIP else { return }

    // Router-Census loggen, sobald sich die Anzahl/Zusammensetzung der RA-Sender ändert.
    logCensusIfChanged(interface: interface, force: false)

    raProtection.refreshVisibility(
      hasGlobalIPv6: hasGlobalIPv6(interface: interface),
      routerCount: ipv6RouterCensus(interface: interface).total)
    raProtection.pollHealth(currentInterface: interface)

    // AP4b: strukturierte Auswertung von `route -n get` statt brüchigem grep.
    let routeValid = routeIsValid(expectedRouter: rIP, interface: interface)

    if routeValid {
      updateIcon(status: .ok)
      let changed = (lastRouteValid != true)
      lastRouteValid = true
      // Ausfall-Episode beendet -> nächster Verlust darf wieder einen Snapshot ziehen.
      outageSnapshotTaken = false
      if changed || logSuccess {
        // Wiederkehrende OK-Prüfung als Heartbeat markieren, damit der
        // „nur Ereignisse"-Filter im Log-Fenster sie ausblenden kann.
        logger.add(
          NSLocalizedString("Route check: OK", comment: ""), type: .success,
          isHeartbeat: !changed)
      }
    } else {
      let changed = (lastRouteValid != false)
      lastRouteValid = false
      updateIcon(status: .error)
      if changed {
        logger.add(
          NSLocalizedString("❌ Route lost! Starting repair...", comment: ""), type: .error)
        RAProtectionController.markRouteLossEverOccurred()
        // AP6: RA-Zustand im Verlustmoment festhalten (datiert im Logfile) — Datengrundlage,
        // um die „high-pref läuft ab"-Hypothese über viele Verluste zu prüfen.
        logger.add(raStateSummary(interface: interface, tag: "RA@loss"), type: .warning)
      }

      // AP2/AP4: genau EIN Forensik-Snapshot pro Ausfall-Episode, VOR der Reparatur,
      // damit der kaputte Zustand erfasst wird. Kostet ein paar Sekunden, ist aber
      // der eigentliche Hebel fürs Apple-Feedback.
      if !outageSnapshotTaken {
        outageSnapshotTaken = true
        captureDiagnosticSnapshot(reason: "IPv6 default route lost", interface: interface)
      }

      fixRoute(interface: interface)
    }
  }

  // AP4b: liest gateway:/interface: aus `route -n get` und vergleicht strukturiert.
  func routeIsValid(expectedRouter: String, interface: String) -> Bool {
    let result = runCommand("/sbin/route", ["-n", "get", "-inet6", "default"])
    guard result.exitCode == 0 else { return false }

    var gateway = ""
    var ifc = ""
    for line in result.stdout.split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("gateway:") {
        gateway = trimmed.replacingOccurrences(of: "gateway:", with: "")
          .trimmingCharacters(in: .whitespaces)
      } else if trimmed.hasPrefix("interface:") {
        ifc = trimmed.replacingOccurrences(of: "interface:", with: "")
          .trimmingCharacters(in: .whitespaces)
      }
    }
    return ifc == interface && stripScope(gateway) == stripScope(expectedRouter)
  }

  // AP4: läuft seriell auf der Repair-Queue. Frischer Router + Retry mit Backoff +
  // Behandlung von "route already exists".
  func fixRoute(interface: String) {
    // Router im Ausfallmoment frisch auflösen (Gateway/RA könnte gewechselt haben).
    if let fresh = findRouterIP(interface: interface) {
      routerIP = fresh
    }
    guard let rIP = routerIP else {
      logger.add(NSLocalizedString("⚠️ No router found for repair.", comment: ""), type: .error)
      return
    }
    let target = scopedAddress(rIP, interface: interface)

    let backoffs: [UInt32] = [1, 3]  // Sekunden zwischen Versuch 1->2 und 2->3
    var lastExit: Int32 = -1

    for attempt in 1...3 {
      // Vor jedem Versuch prüfen, ob die Route inzwischen wieder existiert.
      if routeIsValid(expectedRouter: rIP, interface: interface) {
        repairSucceeded()
        return
      }

      let result = runCommand(
        "/usr/bin/sudo", ["-n", "/sbin/route", "-n", "add", "-inet6", "default", target])
      lastExit = result.exitCode

      if result.exitCode == 0 {
        repairSucceeded()
        return
      }

      // "route already exists" (File exists): kein echter Fehler, wenn die Route gültig ist.
      if result.stderr.contains("File exists"),
        routeIsValid(expectedRouter: rIP, interface: interface)
      {
        repairSucceeded()
        return
      }

      if attempt < 3 { sleep(backoffs[attempt - 1]) }
    }

    logger.add(
      String(format: NSLocalizedString("⚠️ Repair failed (Code %d).", comment: ""), lastExit),
      type: .error)
    logger.add(NSLocalizedString("ℹ️ See README for sudoers setup.", comment: ""), type: .warning)
  }

  private func repairSucceeded() {
    logger.add(NSLocalizedString("✅ Route repaired", comment: ""), type: .success)
    updateIcon(status: .ok)
    lastRouteValid = true
    outageSnapshotTaken = false
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

    let contentView = ConnectivityView(
      routerIPv6: rIP, routerIPv4: v4Router, interface: iface, raProtection: self.raProtection)

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 580, height: 620),
      styleMask: [.titled, .closable, .resizable],
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

  // Führt ein Binary mit absoluten Pfad + Argument-Array aus (kein Shell-Quoting nötig)
  // und liefert stdout, stderr, Exit-Code und Laufzeit zurück.
  struct CommandResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    let duration: TimeInterval
  }

  func runCommand(_ launchPath: String, _ arguments: [String]) -> CommandResult {
    let task = Process()
    let outPipe = Pipe()
    let errPipe = Pipe()
    task.executableURL = URL(fileURLWithPath: launchPath)
    task.arguments = arguments
    task.standardOutput = outPipe
    task.standardError = errPipe

    let start = Date()
    do {
      try task.run()
    } catch {
      return CommandResult(
        stdout: "", stderr: "launch error: \(error)", exitCode: -1, duration: 0)
    }

    // stderr nebenläufig lesen, damit große stdout-Ausgaben (z. B. `log show`) keinen Deadlock
    // verursachen, falls stderr parallel den Pipe-Puffer füllt.
    var errData = Data()
    let errSem = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      errData = errPipe.fileHandleForReading.readDataToEndOfFile()
      errSem.signal()
    }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    errSem.wait()
    task.waitUntilExit()

    return CommandResult(
      stdout: String(data: outData, encoding: .utf8) ?? "",
      stderr: String(data: errData, encoding: .utf8) ?? "",
      exitCode: task.terminationStatus,
      duration: Date().timeIntervalSince(start))
  }

  private func currentFullTimestamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
    return formatter.string(from: Date())
  }

  // AP6: Kompakte, greppbare RA-Zustandszeile. Stabiler (nicht lokalisierter) `tag`-Marker
  // (`RA@loss` beim Verlust, `RA@boot` beim Start) + expire je Preference, damit man über viele
  // Ereignisse per grep den `high`-`expire` und die Zusammensetzung vergleichen kann.
  func raStateSummary(interface: String, tag: String) -> String {
    let routers = RADiagnostics.routers(interface: interface)
    func expires(_ pref: String) -> String {
      routers.filter { $0.pref == pref }.map { $0.expire }.joined(separator: ",")
    }
    return
      "\(tag) total=\(routers.count) high=[\(expires("high"))] medium=[\(expires("medium"))] low=[\(expires("low"))]"
  }

  // Zeitfenster nach System-Boot, in dem ein App-Start als „frisch gebootet" gilt.
  // Nur dann ist die Boot-Baseline diagnostisch sinnvoll (Konvergenz der Default-Router-Liste);
  // ein bloßer App-Neustart Stunden später soll keinen Snapshot erzeugen.
  private let freshBootWindow: TimeInterval = 600  // 10 Minuten

  // Wall-clock-Sekunden seit System-Boot via `kern.boottime` (robust gegen Sleep, anders als
  // ProcessInfo.systemUptime, das nur die Wachzeit zählt).
  private func secondsSinceBoot() -> TimeInterval {
    var mib = [CTL_KERN, KERN_BOOTTIME]
    var bootTime = timeval()
    var size = MemoryLayout<timeval>.stride
    guard sysctl(&mib, 2, &bootTime, &size, nil, 0) == 0, bootTime.tv_sec != 0 else {
      return .infinity  // unbekannt -> NICHT als frisch werten
    }
    let boot = TimeInterval(bootTime.tv_sec) + TimeInterval(bootTime.tv_usec) / 1_000_000
    return Date().timeIntervalSince1970 - boot
  }

  // AP7: Boot-Baseline. Nur kurz nach echtem System-Boot den vollständigen IPv6-Router-/Route-Zustand
  // festhalten (datierte `RA@boot`-Zeile + `startup-…`-Snapshot), um „saubere" vs. „fragile" Boots zu
  // vergleichen. Läuft im Hintergrund, da die Diagnose-Befehle ein paar Sekunden brauchen.
  func captureStartupBaseline(interface: String) {
    let uptime = secondsSinceBoot()
    guard uptime <= freshBootWindow else {
      // App nur neu gestartet, System lief schon länger -> keine (irreführende) Boot-Baseline.
      logger.add(
        "Startup-Baseline übersprungen (kein frischer Boot, uptime=\(Int(uptime))s)", type: .info)
      return
    }
    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self = self else { return }
      self.logger.add(self.raStateSummary(interface: interface, tag: "RA@boot"), type: .info)
      self.captureDiagnosticSnapshot(
        reason: "App startup baseline", interface: interface, filePrefix: "startup")
    }
  }

  // MARK: - AP2: Forensik-Snapshot

  // `filePrefix` trennt die Boot-Baseline (`startup-…`) von den Verlust-Snapshots (`snapshot-…`),
  // damit beide unabhängig auffindbar/prunebar sind.
  func captureDiagnosticSnapshot(reason: String, interface: String, filePrefix: String = "snapshot")
  {
    guard let dir = logger.logDirectoryURL else { return }

    let raTag = filePrefix == "startup" ? "RA@boot" : "RA@loss"
    let nameFormatter = DateFormatter()
    nameFormatter.locale = Locale(identifier: "en_US_POSIX")
    nameFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    let fileURL = dir.appendingPathComponent(
      "\(filePrefix)-\(nameFormatter.string(from: Date())).txt")

    var out = ""
    out += "==== IPv6Monitor Diagnostic Snapshot ====\n"
    out += "Reason:          \(reason)\n"
    out += "Timestamp:       \(currentFullTimestamp())\n"
    out += "Interface:       \(interface)\n"
    out += "Expected router: \(routerIP ?? "-")\n"
    out += "macOS:           \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
    let appVer = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
    out += "App version:     \(appVer) (\(build))\n"
    if let lastPath = lastPathDescription { out += "Last NWPath:     \(lastPath)\n" }
    let census = ipv6RouterCensus(interface: interface)
    out += "IPv6 routers:    \(census.summary)\n"
    out += "RA state:        \(raStateSummary(interface: interface, tag: raTag))\n"
    out += "\n"

    if !census.routers.isEmpty {
      out += section(
        "IPv6 default routers (ndp -rn, RA senders on \(interface))",
        census.routers.joined(separator: "\n"))
    }

    // SystemConfiguration-API-Sicht
    out += section(
      "SCDynamicStore State:/Network/Global/IPv6",
      dictDescription(getSCDynamicStoreValue(key: "State:/Network/Global/IPv6")))
    out += section(
      "SCDynamicStore State:/Network/Interface/\(interface)/IPv6",
      dictDescription(getSCDynamicStoreValue(key: "State:/Network/Interface/\(interface)/IPv6")))

    // Lesende Diagnose-Befehle (absolute Pfade, konsistent mit dem restlichen Stil).
    // Caveat: `ndp -an` zeigt nur den Neighbor-Cache, nicht zwingend ALLE RA-Sender im LAN.
    let commands: [(String, [String])] = [
      ("/sbin/route", ["-n", "get", "-inet6", "default"]),
      // Scoped-Variante: zeigt, ob die `%interface`-scoped Default-Route noch auflöst,
      // während die unscoped oben „not in table" liefert — direkter Beleg für die
      // Konsistenz-Diskrepanz Kernel-Scoped-Route ↔ unscoped Lookup (Apple-Report).
      ("/sbin/route", ["-n", "get", "-inet6", "default", "-ifscope", interface]),
      ("/sbin/route", ["-n", "get", "-inet6", "2001:4860:4860::8888"]),
      ("/usr/sbin/netstat", ["-rn", "-f", "inet6"]),
      ("/usr/sbin/ndp", ["-rn"]),
      ("/usr/sbin/ndp", ["-an"]),
      ("/sbin/ifconfig", [interface]),
      ("/usr/sbin/scutil", ["--nwi"]),
      ("/usr/sbin/networksetup", ["-listallhardwareports"]),
      (
        "/usr/sbin/sysctl",
        ["net.inet6.ip6.accept_rtadv", "net.inet6.ip6.forwarding", "net.inet6.icmp6.nd6_debug"]
      ),
      (
        "/usr/bin/log",
        [
          "show", "--last", "2m", "--info",
          "--predicate",
          "process == \"configd\" OR process == \"networkd\" OR process == \"mDNSResponder\"",
        ]
      ),
    ]
    for (path, args) in commands {
      let r = runCommand(path, args)
      var body = r.stdout
      if !r.stderr.isEmpty { body += "\n[stderr]\n\(r.stderr)" }
      body += "\n[exit=\(r.exitCode), \(String(format: "%.2f", r.duration))s]"
      out += section(([path] + args).joined(separator: " "), body)
    }

    do {
      try out.data(using: .utf8)?.write(to: fileURL)
      logger.add(
        String(
          format: NSLocalizedString("📄 Diagnostic snapshot saved: %@", comment: ""),
          fileURL.lastPathComponent), type: .info)
    } catch {
      logger.add(
        String(
          format: NSLocalizedString("⚠️ Snapshot save failed: %@", comment: ""),
          error.localizedDescription), type: .warning)
    }
  }

  private func section(_ title: String, _ body: String) -> String {
    return "----- \(title) -----\n\(body)\n\n"
  }

  private func dictDescription(_ dict: [String: Any]?) -> String {
    guard let dict = dict else { return "(nil)" }
    return dict.map { "\($0.key) = \($0.value)" }.sorted().joined(separator: "\n")
  }

  // MARK: - AP3: NWPath-Kontext

  func logPathChange(_ path: NWPath) {
    let desc = describePath(path)
    guard desc != lastPathDescription else { return }
    lastPathDescription = desc
    logger.add(
      String(format: NSLocalizedString("Network path: %@", comment: ""), desc), type: .info)
  }

  private func describePath(_ path: NWPath) -> String {
    let status: String
    switch path.status {
    case .satisfied: status = "satisfied"
    case .unsatisfied: status = "unsatisfied"
    case .requiresConnection: status = "requiresConnection"
    @unknown default: status = "unknown"
    }
    let ifaces = path.availableInterfaces.map { $0.name }.joined(separator: ",")
    return
      "status=\(status) ifaces=[\(ifaces)] v6=\(path.supportsIPv6) expensive=\(path.isExpensive)"
  }

  // MARK: - AP5: Diagnose exportieren

  @objc func exportDiagnostics() {
    if let dir = logger.logDirectoryURL {
      NSWorkspace.shared.open(dir)
    }
  }

  // MARK: - IPv6-Router-Census (RA-Sender im Netz)

  struct RouterCensus {
    let total: Int
    let high: Int
    let medium: Int
    let low: Int
    let routers: [String]  // Rohzeilen für den Snapshot

    var summary: String {
      return "\(total) (high:\(high) medium:\(medium) low:\(low))"
    }
  }

  // Zählt die vom Kernel via Router Advertisements gelernten Default-Router auf dem
  // Interface (`ndp -rn`). Genau dieses Signal — mehrere RA-Sender im LAN — ist der
  // dokumentierte Auslöser des macOS-Bugs (Thread Border Router, Apple TVs, HomePods …).
  // utun*/VPN-Einträge werden durch den `if=<interface>`-Filter automatisch ausgeschlossen.
  func ipv6RouterCensus(interface: String) -> RouterCensus {
    let result = runCommand("/usr/sbin/ndp", ["-rn"])
    var total = 0
    var high = 0
    var medium = 0
    var low = 0
    var routers: [String] = []

    for raw in result.stdout.split(separator: "\n") {
      let line = String(raw)
      guard line.contains("if=\(interface),") else { continue }
      total += 1
      routers.append(line.trimmingCharacters(in: .whitespaces))
      if line.contains("pref=high") {
        high += 1
      } else if line.contains("pref=low") {
        low += 1
      } else {
        medium += 1  // pref=medium oder leer (Default = medium)
      }
    }
    return RouterCensus(total: total, high: high, medium: medium, low: low, routers: routers)
  }

  func logCensusIfChanged(interface: String, force: Bool) {
    let census = ipv6RouterCensus(interface: interface)
    let summary = census.summary
    guard force || summary != lastCensusSummary else { return }
    lastCensusSummary = summary
    // Mehr als ein Default-Router = potenzieller Bug-Trigger -> als Warnung markieren.
    let type: LogType = census.total > 1 ? .warning : .info
    logger.add(
      String(format: NSLocalizedString("IPv6 routers on %@: %@", comment: ""), interface, summary),
      type: type)
  }

  // Behält nur die jüngsten `keep` Snapshot-Dateien (nach Änderungsdatum).
  func pruneSnapshots(keep: Int, prefix: String = "snapshot-") {
    guard let dir = logger.logDirectoryURL else { return }
    let fm = FileManager.default
    guard
      let files = try? fm.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return }

    let snapshots = files.filter {
      $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "txt"
    }
    guard snapshots.count > keep else { return }

    let sorted = snapshots.sorted {
      let d0 =
        (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast
      let d1 =
        (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast
      return d0 > d1  // neueste zuerst
    }
    for url in sorted.dropFirst(keep) {
      try? fm.removeItem(at: url)
    }
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

      // Versionszeile (ausgegraut), damit man die gerade laufende Build-Version sofort sieht.
      let appVer = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
      let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
      menu.addItem(
        NSMenuItem(title: "IPv6Monitor \(appVer) (\(build))", action: nil, keyEquivalent: ""))
      menu.addItem(NSMenuItem.separator())

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
          title: NSLocalizedString("Export Diagnostics...", comment: ""),
          action: #selector(self.exportDiagnostics), keyEquivalent: "e"))
      menu.addItem(
        NSMenuItem(
          title: NSLocalizedString("Change Interface...", comment: ""),
          action: #selector(self.changeInterface), keyEquivalent: "i"))

      if self.raProtection.showsControls {
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: self.raProtectionMenuStatus(), action: nil, keyEquivalent: ""))
        if case .active = self.raProtection.uiState {
          menu.addItem(
            NSMenuItem(
              title: NSLocalizedString("RA Protection: Turn off", comment: ""),
              action: #selector(self.disarmRAProtection), keyEquivalent: ""))
        }
      }

      menu.addItem(NSMenuItem.separator())
      menu.addItem(
        NSMenuItem(
          title: NSLocalizedString("Quit", comment: ""),
          action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

      self.statusItem?.menu = menu
    }
  }

  @objc func changeInterface() { openInterfaceSelectionWindow() }

  private func raProtectionMenuStatus() -> String {
    switch raProtection.uiState {
    case .active: return NSLocalizedString("RA Protection: active", comment: "")
    case .preparing, .armingConfirm: return NSLocalizedString("RA Protection: checking", comment: "")
    case .autoOffNotice: return NSLocalizedString("RA Protection: ⚠️ auto-off", comment: "")
    default: return NSLocalizedString("RA Protection: off", comment: "")
    }
  }

  @objc func disarmRAProtection() {
    raProtection.disarm()
  }
}

class WindowDelegateHelper: NSObject, NSWindowDelegate {
  let onClose: () -> Void
  init(onClose: @escaping () -> Void) { self.onClose = onClose }
  func windowWillClose(_ notification: Notification) { onClose() }
}

// MARK: - 4b. RA-Diagnose (Router-Advertisement-Sender im Netz)

// Ein vom Kernel via Router Advertisement gelernter Default-Router auf dem Interface.
// Mehrere solcher Sender sind der dokumentierte Auslöser des macOS-IPv6-Bugs.
struct RAEntry: Identifiable {
  let id = UUID()
  let address: String  // fe80::…%enX (Link-Local des Routers)
  let pref: String  // high | medium | low
  let expire: String  // z. B. "29m51s" oder "Never"
  let flags: String

  // Kurzform der Adresse ohne %scope für die Anzeige.
  var shortAddress: String {
    address.split(separator: "%").first.map(String.init) ?? address
  }
}

// Eigenständiger Helfer (eigene Prozessaufrufe), nutzbar von Views ohne AppDelegate-Bezug.
// Hinweis: Eine Hersteller-/MAC-Identifikation der RA-Sender ist hier bewusst nicht enthalten —
// macOS maskiert die Neighbor-Cache-MACs (`ndp -an`) gegenüber der gehärteten GUI-App.
enum RADiagnostics {

  // RA-Default-Router des Interface (Anzahl, Preference, Rest-Lebensdauer).
  static func routers(interface: String) -> [RAEntry] {
    parseRouters(runNDP(["-rn"]), interface: interface)
  }

  // `ndp -rn` -> RAEntry. Key/Value-Tokens (nicht spaltenbasiert), robust gegen leere Felder.
  static func parseRouters(_ output: String, interface: String) -> [RAEntry] {
    var result: [RAEntry] = []
    for raw in output.split(separator: "\n") {
      let line = String(raw)
      guard line.contains("if=\(interface),") else { continue }
      let addr = line.split(separator: " ").first.map(String.init) ?? ""
      guard !addr.isEmpty else { continue }
      let pref = value(in: line, key: "pref=").flatMap { $0.isEmpty ? nil : $0 } ?? "medium"
      let expire = value(in: line, key: "expire=") ?? "?"
      let flags = value(in: line, key: "flags=") ?? ""
      result.append(RAEntry(address: addr, pref: pref, expire: expire, flags: flags))
    }
    return result
  }

  // Liest den Wert eines „key=…"-Tokens bis zum nächsten Komma.
  static func value(in line: String, key: String) -> String? {
    guard let r = line.range(of: key) else { return nil }
    let rest = line[r.upperBound...]
    let end = rest.firstIndex(of: ",") ?? rest.endIndex
    return String(rest[..<end]).trimmingCharacters(in: .whitespaces)
  }

  private static func runNDP(_ args: [String]) -> String {
    let task = Process()
    let outPipe = Pipe()
    let errPipe = Pipe()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/ndp")
    task.arguments = args
    task.standardOutput = outPipe
    task.standardError = errPipe
    do {
      try task.run()
    } catch {
      return ""
    }
    // stdout UND stderr nebenläufig leeren, sonst kann ein vollaufender Pipe-Puffer die Ausgabe
    // abschneiden/blockieren. (Gleiches Muster wie AppDelegate.runCommand.)
    var outData = Data()
    let outSem = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      outData = outPipe.fileHandleForReading.readDataToEndOfFile()
      outSem.signal()
    }
    _ = errPipe.fileHandleForReading.readDataToEndOfFile()
    outSem.wait()
    task.waitUntilExit()
    return String(data: outData, encoding: .utf8) ?? ""
  }
}

// MARK: - 5. SwiftUI Views

// --- Connectivity Check View ---
struct ConnectivityView: View {
  var routerIPv6: String
  var routerIPv4: String
  var interface: String
  @ObservedObject var raProtection: RAProtectionController

  @State private var targets: [PingTarget] = []
  @State private var results: [PingResult] = []
  @State private var raEntries: [RAEntry] = []

  var body: some View {
    VStack(spacing: 0) {
      raPanel

      RAProtectionPanel(controller: raProtection, interface: interface)

      Divider()

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
        Button(NSLocalizedString("Check Again", comment: "")) {
          runTests()
          loadRouters()
        }
        Spacer()
        Text(NSLocalizedString("Timeout: 1s", comment: "")).font(.caption).foregroundColor(
          .secondary)
      }
      .padding()
    }
    .onAppear {
      prepareTargets()
      runTests()
      loadRouters()
    }
  }

  // Panel „IPv6-Router im Netz (RA-Sender)" — das Kernsignal des macOS-Bugs.
  private var raPanel: some View {
    let total = raEntries.count
    let high = raEntries.filter { $0.pref == "high" }.count
    let medium = raEntries.filter { $0.pref == "medium" }.count
    let low = raEntries.filter { $0.pref == "low" }.count
    let warn = total > 1

    return VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 6) {
        Image(
          systemName: warn ? "exclamationmark.triangle.fill" : "antenna.radiowaves.left.and.right"
        )
        .foregroundColor(warn ? .orange : .secondary)
        Text(
          String(
            format: NSLocalizedString("IPv6 routers on the network: %d", comment: ""), total)
        ).bold()
        Text("(high:\(high) · medium:\(medium) · low:\(low))")
          .font(.caption).foregroundColor(.secondary)
        Spacer()
      }
      .padding(.horizontal).padding(.vertical, 8)
      .background(warn ? Color.orange.opacity(0.12) : Color.gray.opacity(0.08))

      if !raEntries.isEmpty {
        ScrollView {
          VStack(spacing: 0) {
            ForEach(raEntries) { entry in
              HStack(spacing: 8) {
                Text(entry.pref.uppercased())
                  .font(.system(size: 9, weight: .bold))
                  .padding(.horizontal, 5).padding(.vertical, 1)
                  .background(prefColor(entry.pref).opacity(0.2))
                  .foregroundColor(prefColor(entry.pref))
                  .cornerRadius(4)
                  .frame(width: 64, alignment: .leading)
                Text(entry.shortAddress)
                  .font(.system(.caption, design: .monospaced))
                  .lineLimit(1).truncationMode(.middle)
                  .frame(maxWidth: .infinity, alignment: .leading)
                Text(entry.expire)
                  .font(.system(.caption, design: .monospaced)).foregroundColor(.secondary)
                  .frame(width: 90, alignment: .trailing)
              }
              .padding(.horizontal).padding(.vertical, 3)
            }
          }
        }
        .frame(maxHeight: 240)
      }
    }
  }

  private func prefColor(_ pref: String) -> Color {
    switch pref {
    case "high": return .blue
    case "low": return .gray
    default: return .orange
    }
  }

  func loadRouters() {
    let iface = interface
    DispatchQueue.global(qos: .userInitiated).async {
      let entries = RADiagnostics.routers(interface: iface)
      DispatchQueue.main.async { self.raEntries = entries }
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

  @State private var searchText: String = ""
  @State private var enabledTypes: Set<LogType> = Set(LogType.allCases)
  @State private var eventsOnly: Bool = false

  // Nach Suche, Typ und „nur Ereignisse" gefilterte Einträge.
  private var filteredEntries: [LogEntry] {
    logger.entries.filter { entry in
      if eventsOnly && entry.isHeartbeat { return false }
      if !enabledTypes.contains(entry.type) { return false }
      if !searchText.isEmpty && !entry.message.localizedCaseInsensitiveContains(searchText) {
        return false
      }
      return true
    }
  }

  private var isFiltering: Bool {
    !searchText.isEmpty || eventsOnly || enabledTypes.count != LogType.allCases.count
  }

  var body: some View {
    VStack(spacing: 0) {
      filterBar
      Divider()
      ScrollViewReader { proxy in
        List {
          ForEach(Array(filteredEntries.enumerated()), id: \.element.id) { index, entry in
            if index == 0 || filteredEntries[index - 1].dayStart != entry.dayStart {
              dateHeader(entry.displayDate)
            }
            HStack(alignment: .top) {
              Text(entry.formattedTime).font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
              Text(entry.message).foregroundColor(entry.type.color).font(
                .system(.body, design: .monospaced))
              Spacer()
            }
            .id(entry.id)
          }
        }
        .onChange(of: filteredEntries.count) {
          if let last = filteredEntries.last {
            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
          }
        }
      }
      Divider()
      HStack {
        Text(entriesCountLabel)
          .font(.caption).foregroundColor(.secondary)
        Spacer()
        Button(action: {
          let pasteboard = NSPasteboard.general
          pasteboard.clearContents()
          pasteboard.setString(
            filteredEntries.map { $0.fullLogString }.joined(separator: "\n"), forType: .string)
        }) { Label(NSLocalizedString("Copy Log", comment: ""), systemImage: "doc.on.doc") }
      }
      .padding().background(Color(NSColor.windowBackgroundColor))
    }
    .frame(minWidth: 400, minHeight: 300)
  }

  // Such-, Typ- und Ereignis-Filterleiste über der Liste.
  private var filterBar: some View {
    HStack(spacing: 10) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").foregroundColor(.secondary)
        TextField(NSLocalizedString("Search", comment: ""), text: $searchText)
          .textFieldStyle(.plain)
        if !searchText.isEmpty {
          Button(action: { searchText = "" }) {
            Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 8).padding(.vertical, 5)
      .background(Color(NSColor.controlBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 6))

      Toggle(NSLocalizedString("Events only", comment: ""), isOn: $eventsOnly)
        .toggleStyle(.checkbox)

      Menu {
        ForEach(LogType.allCases) { type in
          Toggle(
            type.displayName,
            isOn: Binding(
              get: { enabledTypes.contains(type) },
              set: { on in
                if on { enabledTypes.insert(type) } else { enabledTypes.remove(type) }
              }))
        }
        Divider()
        Button(NSLocalizedString("Show all", comment: "")) {
          enabledTypes = Set(LogType.allCases)
        }
      } label: {
        Label(
          NSLocalizedString("Type", comment: ""), systemImage: "line.3.horizontal.decrease.circle")
      }
      .fixedSize()
    }
    .padding(.horizontal).padding(.vertical, 8)
    .background(Color(NSColor.windowBackgroundColor))
  }

  // Trennzeile mit ausgeschriebenem Datum bei Tageswechsel.
  private func dateHeader(_ text: String) -> some View {
    HStack {
      Text(text)
        .font(.caption).bold().foregroundColor(.secondary)
      Spacer()
    }
    .padding(.vertical, 2)
    .listRowSeparator(.hidden)
  }

  private var entriesCountLabel: String {
    if isFiltering {
      return String(
        format: NSLocalizedString("%1$d of %2$d Entries", comment: ""),
        filteredEntries.count, logger.entries.count)
    }
    return String(format: NSLocalizedString("%d Entries", comment: ""), logger.entries.count)
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
              .foregroundColor(
                iface.isRecommended ? .green : (iface.isLikelyPrimary ? .blue : .gray))
            VStack(alignment: .leading, spacing: 2) {
              HStack {
                Text(iface.displayName).font(.headline)
                if iface.isRecommended {
                  badge(
                    NSLocalizedString("Recommended", comment: ""),
                    systemImage: "checkmark.seal.fill",
                    background: Color.green.opacity(0.85), foreground: .white)
                } else if iface.isLikelyPrimary {
                  badge(
                    NSLocalizedString("ACTIVE", comment: ""),
                    background: Color.green.opacity(0.8), foreground: .white)
                }
                // I1: „IPv6"-Badge nur bei echter Global-Unicast-Adresse, nicht bei Link-Local.
                if iface.hasGlobalIPv6 {
                  badge(
                    "IPv6", background: Color.blue.opacity(0.2), foreground: .blue)
                }
              }
              Text("BSD: \(iface.bsdName)").font(.caption).foregroundColor(.gray)
            }
            Spacer()
            Button(NSLocalizedString("Select", comment: "")) { onSelect(iface.bsdName) }
              .buttonStyle(.borderedProminent).tint(
                iface.isRecommended ? .green : (iface.isLikelyPrimary ? .blue : .gray.opacity(0.5)))
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

  // Kleines, abgerundetes Status-Badge (optional mit SF-Symbol) für die Interface-Liste.
  @ViewBuilder
  func badge(_ text: String, systemImage: String? = nil, background: Color, foreground: Color)
    -> some View
  {
    HStack(spacing: 3) {
      if let systemImage { Image(systemName: systemImage).font(.system(size: 9, weight: .bold)) }
      Text(text).font(.system(size: 10, weight: .bold))
    }
    .padding(.horizontal, 6).padding(.vertical, 2)
    .background(background).foregroundColor(foreground).cornerRadius(8)
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
                bsdName: bsd, displayName: name, isLikelyPrimary: likelyPrimary, hasIPv6: hasIPv6,
                hasGlobalIPv6: hasGlobalIPv6))
          }
        }
      }
      // Empfohlene (primär + globales IPv6) zuerst, dann übrige primäre, dann Rest.
      result.sort { a, b in
        if a.isRecommended != b.isRecommended { return a.isRecommended }
        if a.isLikelyPrimary != b.isLikelyPrimary { return a.isLikelyPrimary }
        return false
      }
      DispatchQueue.main.async {
        self.interfaces = result
        self.isLoading = false
      }
    }
  }
}
