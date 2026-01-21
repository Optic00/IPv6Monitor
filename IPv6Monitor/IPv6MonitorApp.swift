import SwiftUI
import AppKit
import SystemConfiguration
import Combine
import Network

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
        
        logger.add("App gestartet.", type: .info)
        
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
        logger.add("Überwachung: \(interface)", type: .info)
        
        self.routerIP = findRouterIP(interface: interface)
        if let ip = routerIP {
            logger.add("Router IP: \(ip)", type: .success)
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
        logger.add("System Wakeup.", type: .info)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            self.checkRoute(logSuccess: true)
        }
    }
    
    @objc func manualCheck() {
        checkRoute(logSuccess: true)
        openConnectivityWindow()
    }
    
    func checkRoute(logSuccess: Bool) {
        guard let interface = currentInterface else { return }
        
        if routerIP == nil {
            routerIP = findRouterIP(interface: interface)
        }
        
        guard let rIP = routerIP else { return }
        
        // CLEANUP: IP bereinigen vor Verwendung
        let cleanIP = rIP.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let checkCommand = "route -n get -inet6 default 2>/dev/null | grep -q '\(cleanIP)%\(interface)'"
        let exitCode = shellExitCode(checkCommand)
        
        if exitCode == 0 {
            updateIcon(status: .ok)
            if logSuccess { logger.add("Route Prüfung: OK", type: .success) }
        } else {
            logger.add("❌ Route verloren! Starte Reparatur...", type: .error)
            updateIcon(status: .error)
            fixRoute(routerIP: cleanIP, interface: interface)
        }
    }
    
    func fixRoute(routerIP: String, interface: String) {
        let cleanIP = routerIP.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = "route -n add -inet6 default \(cleanIP)%\(interface)"
        let appleScript = "do shell script \"\(command)\" with administrator privileges"
        
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: appleScript) {
            scriptObject.executeAndReturnError(&error)
            if error == nil {
                logger.add("✅ Route repariert", type: .success)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.checkRoute(logSuccess: true)
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
    
    @objc func openConnectivityWindow() {
        if connectivityWindow != nil { connectivityWindow?.close() }
        
        let rIP = self.routerIP ?? ""
        let iface = self.currentInterface ?? ""
        
        // IPv4 Router ermitteln
        let v4Router = findIPv4Router(interface: iface) ?? "-"
        
        let contentView = ConnectivityView(routerIPv6: rIP, routerIPv4: v4Router, interface: iface)
        
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.center()
        window.title = "Verbindungs-Check"
        window.contentView = NSHostingView(rootView: contentView)
        window.isReleasedWhenClosed = false
        
        let windowDelegate = WindowDelegateHelper { [weak self] in self?.connectivityWindow = nil }
        window.delegate = windowDelegate
        objc_setAssociatedObject(window, "WindowDelegate", windowDelegate, .OBJC_ASSOCIATION_RETAIN)
        
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.connectivityWindow = window
    }
    
    // MARK: - Shell Helpers
    
    func findRouterIP(interface: String) -> String? {
        let ndpCmd = "ndp -an | awk '$2 == \"\(interface)\" && $1 ~ /^fe80::/ && $NF ~ /R/ { print $1; exit }'"
        let ndpResult = shell(ndpCmd).trimmingCharacters(in: .whitespacesAndNewlines)
        if !ndpResult.isEmpty { return ndpResult }
        
        let netstatCmd = "netstat -rn -f inet6 | awk '$1 == \"default\" && $NF == \"\(interface)\" && $2 ~ /^fe80::/ { sub(/%.*$/, \"\", $2); print $2; exit }'"
        let netstatResult = shell(netstatCmd).trimmingCharacters(in: .whitespacesAndNewlines)
        return netstatResult.isEmpty ? nil : netstatResult
    }
    
    func findIPv4Router(interface: String) -> String? {
        let cmd = "ipconfig getoption \(interface) router"
        let res = shell(cmd).trimmingCharacters(in: .whitespacesAndNewlines)
        return res.isEmpty ? nil : res
    }
    
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
            
            let interfaceTitle = self.currentInterface != nil ? "Interface: \(self.currentInterface!)" : "Kein Interface"
            menu.addItem(NSMenuItem(title: interfaceTitle, action: nil, keyEquivalent: ""))
            
            if let rIP = self.routerIP {
                menu.addItem(NSMenuItem(title: "Router: \(rIP)", action: nil, keyEquivalent: ""))
            }
            
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Verbindungs-Check", action: #selector(self.manualCheck), keyEquivalent: "r"))
            menu.addItem(NSMenuItem(title: "Protokoll anzeigen...", action: #selector(self.openLogWindow), keyEquivalent: "l"))
            menu.addItem(NSMenuItem(title: "Interface ändern...", action: #selector(self.changeInterface), keyEquivalent: "i"))
            
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            
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
                Text("Ziel").frame(width: 120, alignment: .leading).bold()
                Text("IPv4 (ms)").frame(maxWidth: .infinity, alignment: .leading).bold()
                Text("IPv6 (ms)").frame(maxWidth: .infinity, alignment: .leading).bold()
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            
            Divider()
            
            List(results) { res in
                HStack {
                    Text(res.targetName).frame(width: 120, alignment: .leading).font(.system(.body, design: .monospaced))
                    Text(res.v4Latency).frame(maxWidth: .infinity, alignment: .leading).foregroundColor(res.v4Color).font(.system(.body, design: .monospaced))
                    Text(res.v6Latency).frame(maxWidth: .infinity, alignment: .leading).foregroundColor(res.v6Color).font(.system(.body, design: .monospaced))
                }
            }
            .listStyle(.plain)
            
            Divider()
            
            HStack {
                Button("Neu prüfen") { runTests() }
                Spacer()
                Text("Timeout: 1s").font(.caption).foregroundColor(.secondary)
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
            PingTarget(name: "OpenDNS", ipv4: "208.67.222.222", ipv6: "2620:119:35::35")
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
        
        let routerTarget = PingTarget(name: "Gateway", ipv4: routerIPv4, ipv6: v6Address, isRouter: true)
        t.insert(routerTarget, at: 0)
        self.targets = t
    }
    
    func runTests() {
        results = targets.map { PingResult(targetName: $0.name) }
        
        for (index, target) in targets.enumerated() {
            // IPv4
            if target.ipv4 != "-" && !target.ipv4.isEmpty {
                ping(host: target.ipv4, type: .ipv4) { lat in DispatchQueue.main.async { updateResult(index: index, v4: lat) } }
            } else { DispatchQueue.main.async { updateResult(index: index, v4: -2) } }
            
            // IPv6
            if target.ipv6 != "-" && !target.ipv6.isEmpty {
                ping(host: target.ipv6, type: .ipv6) { lat in DispatchQueue.main.async { updateResult(index: index, v6: lat) } }
            } else { DispatchQueue.main.async { updateResult(index: index, v6: -2) } }
        }
    }
    
    func updateResult(index: Int, v4: Double? = nil, v6: Double? = nil) {
        if let val = v4 {
            if val == -2 { results[index].v4Latency = "-"; results[index].v4Color = .secondary }
            else if val < 0 { results[index].v4Latency = "Timeout"; results[index].v4Color = .red }
            else { results[index].v4Latency = String(format: "%.0f", val); results[index].v4Color = .green }
        }
        if let val = v6 {
            if val == -2 { results[index].v6Latency = "-"; results[index].v6Color = .secondary }
            else if val < 0 { results[index].v6Latency = "Timeout"; results[index].v6Color = .red }
            else { results[index].v6Latency = String(format: "%.0f", val); results[index].v6Color = .green }
        }
    }
    
    enum PingType { case ipv4, ipv6 }
    
    func ping(host: String, type: PingType, completion: @escaping (Double) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // WICHTIG: Strikte Trennung.
            // IPv4 -> /sbin/ping
            // IPv6 -> /sbin/ping6 (oft robuster bei Link-Local und Sandboxing-Restriktionen)
            let binary = (type == .ipv6) ? "/sbin/ping6" : "/sbin/ping"
            
            if !FileManager.default.fileExists(atPath: binary) {
                // Fallback falls ping6 nicht existiert (sehr neue macOS Versionen)
                runPingCommand(binary: "/sbin/ping", host: cleanHost, completion: completion)
                return
            }
            
            runPingCommand(binary: binary, host: cleanHost, completion: completion)
        }
    }
    
    func runPingCommand(binary: String, host: String, completion: @escaping (Double) -> Void) {
        let task = Process()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe() // Fehler ignorieren
        task.launchPath = binary
        // Argumente: -c 1 (Count), -n (No DNS), -W 1000 (Timeout 1s)
        // Bei manchen ping6 Versionen ist -i oder -W anders, aber macOS Standard ist konsistent.
        task.arguments = ["-c", "1", "-n", "-W", "1000", host]
        
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8),
                   let range = output.range(of: "time=([0-9.]+)", options: .regularExpression) {
                    let timeStr = String(output[range]).replacingOccurrences(of: "time=", with: "")
                    if let time = Double(timeStr) {
                        completion(time)
                        return
                    }
                }
                completion(0.0) // Erfolg, aber Zeit nicht parsbar
            } else {
                completion(-1.0) // Fehler
            }
        } catch {
            completion(-1.0)
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
                        Text(entry.formattedTime).font(.system(.caption, design: .monospaced)).foregroundColor(.secondary)
                        Text(entry.message).foregroundColor(entry.type.color).font(.system(.body, design: .monospaced))
                        Spacer()
                    }
                    .id(entry.id)
                }
                .onChange(of: logger.entries.count) {
                    if let last = logger.entries.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            Divider()
            HStack {
                Text("\(logger.entries.count) Einträge").font(.caption).foregroundColor(.secondary)
                Spacer()
                Button(action: {
                    let pasteboard = NSPasteboard.general; pasteboard.clearContents(); pasteboard.setString(logger.getCopyString(), forType: .string)
                }) { Label("Log kopieren", systemImage: "doc.on.doc") }
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
                Image(systemName: "network.badge.shield.half.filled").font(.system(size: 40)).foregroundColor(.blue).padding(.top, 20)
                Text("Interface Überwachung").font(.title2).bold()
                Text("Wählen Sie das Interface mit Internetverbindung.").font(.caption).foregroundColor(.secondary)
            }
            .padding(.bottom, 20)
            Divider()
            if isLoading { Spacer(); ProgressView("Analysiere Netzwerk..."); Spacer() } else {
                List(interfaces) { iface in
                    HStack(alignment: .center) {
                        Image(systemName: iconName(for: iface.displayName)).font(.title2).frame(width: 30).foregroundColor(iface.isLikelyPrimary ? .blue : .gray)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(iface.displayName).font(.headline)
                                if iface.isLikelyPrimary { Text("AKTIV").font(.system(size: 10, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 2).background(Color.green.opacity(0.8)).foregroundColor(.white).cornerRadius(8) }
                                if iface.hasIPv6 { Text("IPv6").font(.system(size: 10, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 2).background(Color.blue.opacity(0.2)).foregroundColor(.blue).cornerRadius(8) }
                            }
                            Text("BSD: \(iface.bsdName)").font(.caption).foregroundColor(.gray)
                        }
                        Spacer()
                        Button("Wählen") { onSelect(iface.bsdName) }.buttonStyle(.borderedProminent).tint(iface.isLikelyPrimary ? .blue : .gray.opacity(0.5))
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
        let lower = name.lowercased(); if lower.contains("wi-fi") || lower.contains("wlan") { return "wifi" }; if lower.contains("ethernet") || lower.contains("lan") { return "cable.connector" }; if lower.contains("thunderbolt") { return "bolt.fill" }; return "network"
    }
    
    func loadInterfaces() {
        DispatchQueue.global(qos: .userInitiated).async {
            var result: [NetworkInterface] = []
            let defaultRouteInterface = shell("route -n get -inet6 default | grep 'interface:' | awk '{print $2}'").trimmingCharacters(in: .whitespacesAndNewlines)
            if let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
                for interface in interfaces {
                    if let bsd = SCNetworkInterfaceGetBSDName(interface) as String?, let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? {
                        let ifconfigOutput = shell("ifconfig \(bsd)")
                        let hasIPv6 = ifconfigOutput.contains("inet6") && !ifconfigOutput.contains("inet6 fe80::%lo0")
                        var likelyPrimary = (bsd == defaultRouteInterface)
                        if !likelyPrimary && hasIPv6 { if ifconfigOutput.contains("inet6 2") || ifconfigOutput.contains("inet6 3") { likelyPrimary = true } }
                        result.append(NetworkInterface(bsdName: bsd, displayName: name, isLikelyPrimary: likelyPrimary, hasIPv6: hasIPv6))
                    }
                }
            }
            result.sort { if $0.isLikelyPrimary && !$1.isLikelyPrimary { return true }; return false }
            DispatchQueue.main.async { self.interfaces = result; self.isLoading = false }
        }
    }
    func shell(_ command: String) -> String {
        let task = Process(); let pipe = Pipe(); task.standardOutput = pipe; task.launchPath = "/bin/bash"; task.arguments = ["-c", command]; try? task.run(); task.waitUntilExit(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); return String(data: data, encoding: .utf8) ?? ""
    }
}
