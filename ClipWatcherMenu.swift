#!/usr/bin/swift

import Cocoa

// ── Configuration ───────────────────────────────────────────────────────────

let SCRIPT_PATH = NSString("~/scripts/clip-watcher.sh").expandingTildeInPath
let PID_FILE = NSString("~/Movies/Captures/encoded/.clip-watcher.pid").expandingTildeInPath
let LOG_FILE = NSString("~/Movies/Captures/encoded/clip-watcher.log").expandingTildeInPath

// ── Menu Bar App ────────────────────────────────────────────────────────────

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
        updateStatus()
        
        // Update status every 5 seconds
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            self.updateStatus()
        }
    }
    
    func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.title = "Clip Watcher"
            button.action = #selector(statusBarButtonClicked(_:))
        }
        
        setupMenu()
    }
    
    func setupMenu() {
        let menu = NSMenu()
        
        // Status header
        let statusItem = NSMenuItem(title: "Status: Checking...", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Actions
        menu.addItem(NSMenuItem(title: "Start", action: #selector(startWatcher), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: "Stop", action: #selector(stopWatcher), keyEquivalent: "x"))
        
        menu.addItem(NSMenuItem.separator())
        
        menu.addItem(NSMenuItem(title: "Status", action: #selector(showStatus), keyEquivalent: "i"))
        menu.addItem(NSMenuItem(title: "Copy Last Link", action: #selector(copyLastLink), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: "Tail Log", action: #selector(tailLog), keyEquivalent: "l"))
        
        menu.addItem(NSMenuItem.separator())
        
        menu.addItem(NSMenuItem(title: "Clear Processed", action: #selector(clearProcessed), keyEquivalent: ""))
        
        menu.addItem(NSMenuItem.separator())
        
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem.menu = menu
    }
    
    @objc func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        // Menu will show automatically
    }
    
    // ── Status Updates ──────────────────────────────────────────────────────
    
    func updateStatus() {
        let isRunning = checkIfRunning()
        
        if let button = statusItem.button {
            button.title = isRunning ? "▶ Clip Watcher" : "⏹ Clip Watcher"
        }
        
        // Update status menu item
        if let menu = statusItem.menu, let statusItem = menu.items.first {
            statusItem.title = isRunning ? "Status: Running" : "Status: Stopped"
        }
    }
    
    func checkIfRunning() -> Bool {
        guard let pidString = try? String(contentsOfFile: PID_FILE, encoding: .utf8) else {
            return false
        }
        
        let pid = pidString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pidInt = Int32(pid) else {
            return false
        }
        
        // Check if process is running
        return kill(pidInt, 0) == 0
    }
    
    // ── Actions ─────────────────────────────────────────────────────────────
    
    @objc func startWatcher() {
        runScript(args: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.updateStatus()
        }
    }
    
    @objc func stopWatcher() {
        runScript(args: ["stop"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.updateStatus()
        }
    }
    
    @objc func showStatus() {
        let output = runScriptWithOutput(args: ["status"])
        showAlert(title: "Clip Watcher Status", message: output)
    }
    
    @objc func copyLastLink() {
        let output = runScriptWithOutput(args: ["last"])
        if output.contains("Copied:") {
            // Extract URL from output
            let components = output.components(separatedBy: "Copied: ")
            if components.count > 1 {
                let urlPart = components[1].components(separatedBy: "  ").first ?? ""
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(urlPart, forType: .string)
                showNotification(title: "Link Copied", message: urlPart)
            }
        } else {
            showNotification(title: "No Links", message: output)
        }
    }
    
    @objc func tailLog() {
        let url = URL(fileURLWithPath: LOG_FILE)
        NSWorkspace.shared.open(url)
    }
    
    @objc func clearProcessed() {
        let alert = NSAlert()
        alert.messageText = "Clear Processed Log"
        alert.informativeText = "This will allow all clips to be re-queued. Continue?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            runScript(args: ["clear"])
            showNotification(title: "Cleared", message: "Processed log cleared")
        }
    }
    
    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    // ── Script Execution ────────────────────────────────────────────────────
    
    @discardableResult
    func runScript(args: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: SCRIPT_PATH)
        task.arguments = args
        
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus
        } catch {
            print("Error running script: \(error)")
            return -1
        }
    }
    
    func runScriptWithOutput(args: [String]) -> String {
        let task = Process()
        let pipe = Pipe()
        
        task.executableURL = URL(fileURLWithPath: SCRIPT_PATH)
        task.arguments = args
        task.standardOutput = pipe
        task.standardError = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? "No output"
        } catch {
            return "Error: \(error)"
        }
    }
    
    // ── Notifications ───────────────────────────────────────────────────────
    
    func showNotification(title: String, message: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = message
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
    }
    
    func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

// ── Main ────────────────────────────────────────────────────────────────────

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
