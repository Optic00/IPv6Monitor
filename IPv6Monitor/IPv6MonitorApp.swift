// Testversion 0.1

import SwiftUI
import AppKit
import SystemConfiguration
import Combine
import Network

// MARK: - 1. Datenmodelle

struct NetworkInterface: Identifiable, Hashable {
    let id = UUID()
    let bsdName: String      // z.B. "en0"
    let displayName: String  // z.B. "Wi-Fi"
    var isLikelyPrimary: Bool = false // Ist das Interface aktiv?
    var hasIPv6: Bool = false         // Hat es IPv6?
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
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
    
    var fullLogString: String {
        return "[\(formattedTime)] \(type.prefix) \(message)"
    }
}

// MARK: - 2. Logger (ObservableObject)

class Logger: ObservableObject {
    @Published var entries: [LogEntry] = []
    
    func add(_ message: String, type: LogType = .info) {
        DispatchQueue.main.async {
            let entry = LogEntry(date: Date(), message: message, type: type)
            self.entries.append(entry)
            // Begrenzung auf 500 Einträge, um Speicher zu sparen
            if self.entries.count > 500 { self.entries.removeFirst() }
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
    
    // Netzwerk Monitor (Event-basiert statt Polling)
    var pathMonitor: NWPathMonitor?
    var monitorQueue = DispatchQueue(label: "NetworkMonitorQueue")
    
    var currentInterface: String?
    var routerIP: String?
    
    var logger = Logger()
    
    // Fenster Referenzen
    var settingsWindow: NSWindow?
    var logWindow: NSWindow?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Status Item erstellen
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon(status: .neutral)
        
        logger.add("App gestartet. Initialisiere...", type: .info)
        
        // Listener für "Aufwachen aus Standby"
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(wakeUpCheck),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        
        // Interface laden oder abfragen
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
        logger.add("Überwachung gestartet für: \(interface)", type: .info)
        
        // 1. Router IP ermitteln
        self.routerIP = findRouterIP(interface: interface)
        if let ip = routerIP {
            logger.add("Router IP erkannt: \(ip)", type: .success)
        } else {
            logger.add("Router IP noch nicht gefunden. Warte auf Netzwerk...", type: .warning)
        }
        
        // 2. Sofort-Check
        checkRoute()
        
        // 3. Native Netzwerk-Events abonnieren
        pathMonitor = NWPathMonitor()
        pathMonitor?.pathUpdateHandler = { [weak self] path in
            self?.logger.add("Netzwerk-Status hat sich geändert", type: .info)
            // Kurze Wartezeit, damit DHCP/RA fertig sind
            DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 2.0) {
                self?.checkRoute()
            }
        }
        pathMonitor?.start(queue: monitorQueue)
        
        constructMenu()
    }
    
    @objc func wakeUpCheck() {
        logger.add("System aufgewacht. Prüfe Verbindungen...", type: .info)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            self.checkRoute()
        }
    }
    
    @objc func checkRoute() {
        guard let interface = currentInterface else { return }
        
        // Falls Router IP fehlt, neu suchen
        if routerIP == nil {
            routerIP = findRouterIP(interface: interface)
        }
        
        guard let rIP = routerIP else {
            // Ohne Router IP können wir keine Route prüfen
            return
        }
        
        // Prüfen ob die Default Route für diese Router-IP existiert
        let checkCommand = "route -n get -inet6 default 2>/dev/null | grep -q '\(rIP)%\(interface)'"
        let exitCode = shellExitCode(checkCommand)
        
        if exitCode == 0 {
            updateIcon(status: .ok)
        } else {
            logger.add("❌ Route verloren! Starte Reparatur...", type: .error)
            updateIcon(status: .error)
            fixRoute(routerIP: rIP, interface: interface)
        }
    }
    
    func fixRoute(routerIP: String, interface: String) {
        let command = "route -n add -inet6 default \(routerIP)%\(interface)"
        let appleScript = "do shell script \"\(command)\" with administrator privileges"
        
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: appleScript) {
            scriptObject.executeAndReturnError(&error)
            if error == nil {
                logger.add("✅ Route erfolgreich repariert", type: .success)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.checkRoute()
                }
            } else {
                logger.add("⚠️ Reparatur fehlgeschlagen: \(String(describing: error))", type: .error)
            }
        }
    }
    
    // MARK: - Fenster Management
    
    func openInterfaceSelectionWindow() {
        if settingsWindow != nil { settingsWindow?.makeKeyAndOrderFront(nil); return }
        
        let contentView = InterfaceSelectionView { [weak self] selectedBsdName in
            self?.currentInterface = selectedBsdName
            UserDefaults.standard.set(selectedBsdName, forKey: "selectedInterface")
            self?.settingsWindow?.close()
            self?.settingsWindow = nil
            self?.startMonitoring()
        }
        
        // Großes Fenster für bessere Übersicht (500x500)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.center()
        window.title = "Interface wählen"
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
        if logWindow != nil { logWindow?.makeKeyAndOrderFront(nil); return }
        
        let contentView = LogView(logger: self.logger)
        
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.center()
        window.title = "Protokoll"
        window.contentView = NSHostingView(rootView: contentView)
        window.isReleasedWhenClosed = false
        
        let windowDelegate = WindowDelegateHelper { [weak self] in self?.logWindow = nil }
        window.delegate = windowDelegate
        objc_setAssociatedObject(window, "WindowDelegate", windowDelegate, .OBJC_ASSOCIATION_RETAIN)
        
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.logWindow = window
    }
    
    // MARK: - Shell Helpers
    
    func findRouterIP(interface: String) -> String? {
        // 1. Versuch: NDP
        let ndpCmd = "ndp -an | awk '$2 == \"\(interface)\" && $1 ~ /^fe80::/ && $NF ~ /R/ { print $1; exit }'"
        let ndpResult = shell(ndpCmd).trimmingCharacters(in: .whitespacesAndNewlines)
        if !ndpResult.isEmpty { return ndpResult }
        
        // 2. Versuch: Netstat
        let netstatCmd = "netstat -rn -f inet6 | awk '$1 == \"default\" && $NF == \"\(interface)\" && $2 ~ /^fe80::/ { sub(/%.*$/, \"\", $2); print $2; exit }'"
        let netstatResult = shell(netstatCmd).trimmingCharacters(in: .whitespacesAndNewlines)
        return netstatResult.isEmpty ? nil : netstatResult
    }
    
    func shell(_ command: String) -> String {
        let task = Process()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", command]
        try? task.run()
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
            
            let interfaceTitle = self.currentInterface != nil ? "Interface: \(self.currentInterface!)" : "Kein Interface"
            menu.addItem(NSMenuItem(title: interfaceTitle, action: nil, keyEquivalent: ""))
            
            if let rIP = self.routerIP {
                menu.addItem(NSMenuItem(title: "Router: \(rIP)", action: nil, keyEquivalent: ""))
            } else {
                menu.addItem(NSMenuItem(title: "Router: Suche...", action: nil, keyEquivalent: ""))
            }
            
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Protokoll anzeigen...", action: #selector(self.openLogWindow), keyEquivalent: "l"))
            menu.addItem(NSMenuItem(title: "Interface ändern...", action: #selector(self.changeInterface), keyEquivalent: "i"))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Jetzt prüfen", action: #selector(self.checkRoute), keyEquivalent: "r"))
            menu.addItem(NSMenuItem(title: "Beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            
            self.statusItem?.menu = menu
        }
    }
    
    @objc func changeInterface() { openInterfaceSelectionWindow() }
}

// Helper für Fenster-Delegates
class WindowDelegateHelper: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}

// MARK: - 5. SwiftUI Views

struct LogView: View {
    @ObservedObject var logger: Logger
    
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List(logger.entries) { entry in
                    HStack(alignment: .top) {
                        Text(entry.formattedTime)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                        
                        Text(entry.message)
                            .foregroundColor(entry.type.color)
                            .font(.system(.body, design: .monospaced))
                        
                        Spacer()
                    }
                    .id(entry.id)
                }
                // Fix für macOS 14 Warnung: Zero-Parameter Closure nutzen
                .onChange(of: logger.entries.count) {
                    if let last = logger.entries.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            
            Divider()
            
            HStack {
                Text("\(logger.entries.count) Einträge")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(logger.getCopyString(), forType: .string)
                }) {
                    Label("Log kopieren", systemImage: "doc.on.doc")
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 400, minHeight: 300)
    }
}

struct InterfaceSelectionView: View {
    var onSelect: (String) -> Void
    @State private var interfaces: [NetworkInterface] = []
    @State private var isLoading = true
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "network.badge.shield.half.filled")
                    .font(.system(size: 40))
                    .foregroundColor(.blue)
                    .padding(.top, 20)
                
                Text("Interface Überwachung")
                    .font(.title2)
                    .bold()
                
                Text("Wählen Sie das Interface mit Internetverbindung.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 20)
            
            Divider()
            
            if isLoading {
                Spacer()
                ProgressView("Analysiere Netzwerk...")
                Spacer()
            } else {
                List(interfaces) { iface in
                    HStack(alignment: .center) {
                        Image(systemName: iconName(for: iface.displayName))
                            .font(.title2)
                            .frame(width: 30)
                            .foregroundColor(iface.isLikelyPrimary ? .blue : .gray)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(iface.displayName)
                                    .font(.headline)
                                    .foregroundColor(iface.isLikelyPrimary ? .primary : .secondary)
                                
                                if iface.isLikelyPrimary {
                                    Text("AKTIV")
                                        .font(.system(size: 10, weight: .bold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.green.opacity(0.8))
                                        .foregroundColor(.white)
                                        .cornerRadius(8)
                                }
                                
                                if iface.hasIPv6 {
                                    Text("IPv6")
                                        .font(.system(size: 10, weight: .bold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.2))
                                        .foregroundColor(.blue)
                                        .cornerRadius(8)
                                }
                            }
                            Text("BSD: \(iface.bsdName)")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        
                        Spacer()
                        
                        Button("Wählen") { onSelect(iface.bsdName) }
                            .buttonStyle(.borderedProminent)
                            .tint(iface.isLikelyPrimary ? .blue : .gray.opacity(0.5))
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
        if lower.contains("iphone") || lower.contains("hotspot") { return "iphone" }
        return "network"
    }
    
    func loadInterfaces() {
        DispatchQueue.global(qos: .userInitiated).async {
            var result: [NetworkInterface] = []
            
            // Default Route Interface ermitteln
            let defaultRouteInterface = shell("route -n get -inet6 default | grep 'interface:' | awk '{print $2}'").trimmingCharacters(in: .whitespacesAndNewlines)
            
            if let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
                for interface in interfaces {
                    if let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
                       let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? {
                        
                        // IPv6 Check via ifconfig
                        let ifconfigOutput = shell("ifconfig \(bsd)")
                        let hasIPv6 = ifconfigOutput.contains("inet6") && !ifconfigOutput.contains("inet6 fe80::%lo0")
                        
                        var likelyPrimary = (bsd == defaultRouteInterface)
                        
                        // Fallback Heuristik
                        if !likelyPrimary && hasIPv6 {
                            if ifconfigOutput.contains("inet6 2") || ifconfigOutput.contains("inet6 3") {
                                likelyPrimary = true
                            }
                        }
                        
                        result.append(NetworkInterface(bsdName: bsd, displayName: name, isLikelyPrimary: likelyPrimary, hasIPv6: hasIPv6))
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
    
    func shell(_ command: String) -> String {
        let task = Process()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", command]
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
