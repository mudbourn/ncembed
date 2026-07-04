#!/usr/bin/swift

import Cocoa

// ── Configuration ───────────────────────────────────────────────────────────

let CLIP_PATH = NSString("~/Documents/GitHub/ncembed/clip").expandingTildeInPath
let CONFIG_DIR = NSString("~/.config/clip-watcher").expandingTildeInPath
let CONFIG_FILE = "\(CONFIG_DIR)/config.json"
let TEMP_DIR = NSString("~/Movies/Captures/encoded").expandingTildeInPath
let PID_FILE = "\(TEMP_DIR)/.clip-watcher.pid"
let LOG_FILE = "\(TEMP_DIR)/clip-watcher.log"

struct Config: Codable {
    var watchDir: String
    var nextcloudURL: String
    var nextcloudUser: String
    var nextcloudPass: String
    var uploadPath: String
    var ncembedDomain: String
    var useNcembed: Bool
    var sambaShares: [String]
}

func loadConfig() -> Config? {
    guard FileManager.default.fileExists(atPath: CONFIG_FILE) else { return nil }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: CONFIG_FILE)) else { return nil }
    return try? JSONDecoder().decode(Config.self, from: data)
}

// ── Menu Bar App ────────────────────────────────────────────────────────────

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var statusMenuItem: NSMenuItem!
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        
        setupStatusBar()
        updateStatus()
        
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            self.updateStatus()
        }
    }
    
    func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.title = "⏹ Clip"
        }
        
        let menu = NSMenu()
        
        statusMenuItem = NSMenuItem(title: "Status: Checking...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Start", action: #selector(startWatcher), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: "Stop", action: #selector(stopWatcher), keyEquivalent: "x"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Copy Last Link", action: #selector(copyLastLink), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: "Tail Log", action: #selector(tailLog), keyEquivalent: "l"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem.menu = menu
    }
    
    func updateStatus() {
        let running = isWatcherRunning()
        
        if let button = statusItem.button {
            button.title = running ? "▶ Clip" : "⏹ Clip"
        }
        statusMenuItem.title = running ? "Status: Running" : "Status: Stopped"
    }
    
    func isWatcherRunning() -> Bool {
        guard let pidStr = try? String(contentsOfFile: PID_FILE, encoding: .utf8),
              let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return kill(pid, 0) == 0
    }
    
    // ── Actions ─────────────────────────────────────────────────────────────
    
    @objc func startWatcher() {
        runClip("start")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.updateStatus() }
    }
    
    @objc func stopWatcher() {
        runClip("stop")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.updateStatus() }
    }
    
    @objc func copyLastLink() {
        let output = runClipWithOutput("last")
        if output.contains("Copied:") {
            let parts = output.components(separatedBy: "Copied: ")
            if parts.count > 1 {
                let url = parts[1].components(separatedBy: "  ").first ?? ""
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
                notify("Link Copied", url)
            }
        } else {
            notify("No Links", output.isEmpty ? "No uploads recorded yet" : output)
        }
    }
    
    @objc func tailLog() {
        if FileManager.default.fileExists(atPath: LOG_FILE) {
            NSWorkspace.shared.open(URL(fileURLWithPath: LOG_FILE))
        } else {
            notify("No Log", "Log file not found")
        }
    }
    
    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    // ── Helpers ─────────────────────────────────────────────────────────────
    
    @discardableResult
    func runClip(_ args: String...) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l", "-c", "\(CLIP_PATH) \(args.joined(separator: " "))"]
        try? proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus
    }
    
    func runClipWithOutput(_ args: String...) -> String {
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l", "-c", "\(CLIP_PATH) \(args.joined(separator: " "))"]
        proc.standardOutput = pipe
        proc.standardError = pipe
        try? proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    
    func notify(_ title: String, _ message: String) {
        let t = title.replacingOccurrences(of: "\"", with: "\\\"")
        let m = message.replacingOccurrences(of: "\"", with: "\\\"")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", "display notification \"\(m)\" with title \"\(t)\""]
        try? proc.run()
    }
}

// ── Main ────────────────────────────────────────────────────────────────────

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
