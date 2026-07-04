#!/usr/bin/swift

import Cocoa
import Foundation

// MARK: - Configuration

struct ConfigFile: Codable {
    var watchDir: String
    var nextcloudURL: String
    var nextcloudUser: String
    var nextcloudPass: String
    var uploadPath: String
    var ncembedDomain: String
    var useNcembed: Bool
    var sambaShares: [SambaShare]
    
    static let `default` = ConfigFile(
        watchDir: "~/Movies/Captures",
        nextcloudURL: "https://your-nextcloud.example.com",
        nextcloudUser: "",
        nextcloudPass: "",
        uploadPath: "/Videos/clips",
        ncembedDomain: "embed.your-nextcloud.example.com",
        useNcembed: true,
        sambaShares: []
    )
}

struct SambaShare: Codable {
    var mountPath: String
    var nextcloudPath: String
}

struct Config {
    static let configDir = NSString("~/.config/clip-watcher").expandingTildeInPath
    static let configFile = "\(configDir)/config.json"
    static let tempDir = NSString("~/Movies/Captures/encoded").expandingTildeInPath
    static let logFile = "\(tempDir)/clip-watcher.log"
    static let pidFile = "\(tempDir)/.clip-watcher.pid"
    static let urlLog = "\(tempDir)/.urls"
    static let processedLog = "\(tempDir)/.processed"
    
    static let videoExtensions: Set<String> = ["mp4", "mkv", "mov", "avi", "webm"]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff"]
    static let allExtensions: Set<String> = videoExtensions.union(imageExtensions)
    static let stableChecks = 3
    static let stableInterval: TimeInterval = 2.0
    
    static var file: ConfigFile!
    
    static func load() -> Bool {
        let url = URL(fileURLWithPath: configFile)
        guard FileManager.default.fileExists(atPath: configFile) else { return false }
        do {
            let data = try Data(contentsOf: url)
            file = try JSONDecoder().decode(ConfigFile.self, from: data)
            return true
        } catch {
            Logger.shared.error("Failed to load config: \(error)")
            return false
        }
    }
    
    static func save(_ config: ConfigFile) throws {
        try FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: URL(fileURLWithPath: configFile))
    }
}

// MARK: - Logger

class Logger {
    static let shared = Logger()
    private let queue = DispatchQueue(label: "com.clip-watcher.logger", qos: .utility)
    private let df = DateFormatter()
    var onLog: ((String) -> Void)?

    init() { df.dateFormat = "yyyy-MM-dd HH:mm:ss" }

    func log(_ level: String, _ msg: String) {
        let ts = df.string(from: Date())
        let line = "[\(ts)] [\(level)] \(msg)"
        queue.async {
            print(line)
            self.onLog?(line)
            if let data = (line + "\n").data(using: .utf8) {
                if let fh = FileHandle(forWritingAtPath: Config.logFile) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    fh.closeFile()
                } else {
                    try? data.write(to: URL(fileURLWithPath: Config.logFile), options: .atomic)
                }
            }
        }
    }

    func info(_ m: String) { log("INFO ", m) }
    func ok(_ m: String) { log(" OK  ", m) }
    func warn(_ m: String) { log("WARN ", m) }
    func error(_ m: String) { log("ERROR", m) }
    func debug(_ m: String) { log("DEBUG", m) }
    func separator() { log("", "──────────────────────────────────────────────────────────") }
}

// MARK: - NextcloudClient

actor NextcloudClient {
    private let session: URLSession
    private let baseURL: URL
    private let user: String
    private let pass: String

    init?() {
        let u = Config.file.nextcloudUser
        let p = Config.file.nextcloudPass
        guard !u.isEmpty, !p.isEmpty, let url = URL(string: Config.file.nextcloudURL) else {
            Logger.shared.error("Nextcloud credentials not configured. Run: clip setup")
            return nil
        }
        self.user = u
        self.pass = p
        self.baseURL = url
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: cfg)
    }

    private func authValue() -> String {
        "Basic \(Data("\(user):\(pass)".utf8).base64EncodedString())"
    }

    func testConnection() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("ocs/v2.php/cloud/user"))
        req.setValue(authValue(), forHTTPHeaderField: "Authorization")
        req.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        guard let (_, resp) = try? await session.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    func upload(file: String, to path: String) async -> Bool {
        let name = (file as NSString).lastPathComponent
        let remote = baseURL.appendingPathComponent("dav/files/\(user)\(path)/\(name)")
        let dir = baseURL.appendingPathComponent("dav/files/\(user)\(path)")

        var mk = URLRequest(url: dir)
        mk.httpMethod = "MKCOL"
        mk.setValue(authValue(), forHTTPHeaderField: "Authorization")
        let (_, mkResp) = (try? await session.data(for: mk)) ?? (Data(), URLResponse())
        let mkCode = (mkResp as? HTTPURLResponse)?.statusCode ?? 0
        Logger.shared.debug("MKCOL \(dir): HTTP \(mkCode)")

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)) else {
            Logger.shared.error("Failed to read file for upload: \(file)")
            return false
        }
        
        var req = URLRequest(url: remote)
        req.httpMethod = "PUT"
        req.setValue(authValue(), forHTTPHeaderField: "Authorization")
        
        do {
            let (_, resp) = try await session.upload(for: req, from: data)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code >= 200 && code < 300 {
                return true
            } else {
                Logger.shared.error("WebDAV upload failed with HTTP \(code)")
                Logger.shared.error("Upload URL: \(remote)")
                return false
            }
        } catch {
            Logger.shared.error("WebDAV upload request failed: \(error)")
            return false
        }
    }

    func createShare(filePath: String) async -> String? {
        let url = baseURL.appendingPathComponent("ocs/v2.php/apps/files_sharing/api/v1/shares")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(authValue(), forHTTPHeaderField: "Authorization")
        req.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "path=\(filePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filePath)&shareType=3&permissions=1".data(using: .utf8)

        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ocs = json["ocs"] as? [String: Any],
               let meta = ocs["meta"] as? [String: Any] {
                let statusCode = meta["statuscode"] as? Int ?? 0
                let status = meta["status"] as? String ?? ""
                
                if status == "ok" || statusCode == 100 || statusCode == 200 {
                    let d = ocs["data"] as? [String: Any]
                    return d?["token"] as? String
                } else {
                    let message = meta["message"] as? String ?? "unknown error"
                    Logger.shared.error("Share creation failed: \(message) (status: \(statusCode))")
                    Logger.shared.error("Share path: \(filePath)")
                    return nil
                }
            } else {
                let body = String(data: data, encoding: .utf8) ?? "empty response"
                Logger.shared.error("Share creation returned non-JSON (HTTP \(code))")
                Logger.shared.error("Response: \(body.prefix(200))")
                Logger.shared.error("Share path: \(filePath)")
                return nil
            }
        } catch {
            Logger.shared.error("Share creation request failed: \(error)")
            return nil
        }
    }
}

// MARK: - FileWatcher

class FileWatcher {
    private var fd: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private let callback: () -> Void
    private var debounceTimer: DispatchSourceTimer?
    private let debounceQueue = DispatchQueue(label: "com.clip-watcher.debounce")

    init(path: String, callback: @escaping () -> Void) {
        self.callback = callback
        fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            Logger.shared.error("Failed to open watch dir: \(path)")
            return
        }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .attrib],
            queue: DispatchQueue.global(qos: .utility)
        )
        source?.setEventHandler { [weak self] in self?.debouncedCallback() }
        source?.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 { close(fd) }
        }
        source?.resume()
    }

    private func debouncedCallback() {
        debounceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: debounceQueue)
        timer.schedule(deadline: .now() + 1.5)
        timer.setEventHandler { [weak self] in self?.callback() }
        timer.resume()
        debounceTimer = timer
    }

    deinit { source?.cancel() }
}

// MARK: - ClipProcessor

class ClipProcessor {
    let nextcloud: NextcloudClient?
    private let queue = DispatchQueue(label: "com.clip-watcher.proc", qos: .userInitiated)
    private var processed = Set<String>()
    private var inFlight = Set<String>()
    private let lock = NSRecursiveLock()
    var onStatusChange: (() -> Void)?

    init() { nextcloud = NextcloudClient(); loadProcessed() }

    private func loadProcessed() {
        guard let s = try? String(contentsOfFile: Config.processedLog, encoding: .utf8) else { return }
        processed = Set(s.components(separatedBy: .newlines).filter { !$0.isEmpty })
    }

    func process(file: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !processed.contains(file), !inFlight.contains(file) else { return }
        inFlight.insert(file)
        queue.async { self.processFile(file) }
    }

    private func processFile(_ file: String) {
        let name = (file as NSString).lastPathComponent
        Logger.shared.info("[\(name)] Processing started")
        Logger.shared.info("[\(name)] Waiting for file to stabilize...")

        guard waitForStable(file) else {
            Logger.shared.error("[\(name)] File never stabilized, skipping")
            removeInFlight(file)
            return
        }

        let sz = fileSize(file)
        Logger.shared.info("[\(name)] File ready: \(sz / 1024 / 1024)MB")

        Task {
            guard let nc = nextcloud else {
                Logger.shared.error("Nextcloud client not available")
                removeInFlight(file)
                return
            }

            Logger.shared.info("Uploading: \(name) (\(sz / 1024 / 1024)MB)")

            let ext = (name as NSString).pathExtension.lowercased()
            let subfolder = Config.imageExtensions.contains(ext) ? "Images" : "Videos"
            let uploadPath = "\(Config.file.uploadPath)/\(subfolder)"

            var sambaSuccess = false
            var nextcloudFilePath: String?
            
            if let samba = sambaRoot() {
                Logger.shared.info("Using Samba share: \(samba.mountPath)")
                let dest = "\(samba.mountPath)\(uploadPath)/\(name)"
                let destDir = "\(samba.mountPath)\(uploadPath)"
                if (try? FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)) != nil,
                   (try? FileManager.default.copyItem(atPath: file, toPath: dest)) != nil {
                    sambaSuccess = true
                    nextcloudFilePath = "\(samba.nextcloudPath)\(uploadPath)/\(name)"
                    Logger.shared.ok("Copied to Samba: \(dest)")
                    Logger.shared.info("Nextcloud path: \(nextcloudFilePath ?? "unknown")")
                } else {
                    Logger.shared.warn("Samba copy failed, falling back to WebDAV")
                }
            }

            if !sambaSuccess {
                let basePath = Config.file.sambaShares.first?.nextcloudPath ?? Config.file.uploadPath
                nextcloudFilePath = "\(basePath)\(uploadPath)/\(name)"
                
                let ok = await nc.upload(file: file, to: "\(basePath)\(uploadPath)")
                guard ok else {
                    Logger.shared.error("Upload failed for \(name)")
                    removeInFlight(file)
                    return
                }
                Logger.shared.ok("Uploaded via WebDAV: \(nextcloudFilePath ?? "unknown")")
            }

            guard let filePath = nextcloudFilePath else {
                Logger.shared.error("No file path available for share creation")
                removeInFlight(file)
                return
            }
            
            guard let token = await nc.createShare(filePath: filePath) else {
                Logger.shared.error("Failed to create share for \(name)")
                removeInFlight(file)
                return
            }

            let url = Config.file.useNcembed
                ? "https://\(Config.file.ncembedDomain)/embed/\(token)"
                : "\(Config.file.nextcloudURL)/s/\(token)"

            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url, forType: .string)

            let ts = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
            appendFile(Config.urlLog, "\(ts)\t\(url)\t\(name)\n")

            Logger.shared.ok("Link copied: \(url)")
            sendNotification(title: "Clip Ready", message: url)

            lock.lock()
            processed.insert(file)
            inFlight.remove(file)
            lock.unlock()
            appendFile(Config.processedLog, file + "\n")
            Logger.shared.ok("[\(name)] Done")
            Logger.shared.separator()
            
            DispatchQueue.main.async { self.onStatusChange?() }
        }
    }

    private func waitForStable(_ file: String) -> Bool {
        var prev = fileSize(file), stable = 0
        for _ in 0..<30 {
            Thread.sleep(forTimeInterval: Config.stableInterval)
            let cur = fileSize(file)
            if cur == prev && cur > 0 { stable += 1; if stable >= Config.stableChecks { return true } }
            else { stable = 0 }
            prev = cur
        }
        return false
    }

    private func fileSize(_ f: String) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: f)[.size] as? Int) ?? 0
    }

    private func sambaRoot() -> SambaShare? {
        Config.file.sambaShares.first { FileManager.default.fileExists(atPath: $0.mountPath) }
    }

    private func removeInFlight(_ f: String) {
        lock.lock(); inFlight.remove(f); lock.unlock()
    }

    private func appendFile(_ path: String, _ content: String) {
        guard let d = content.data(using: .utf8) else { return }
        if let fh = FileHandle(forWritingAtPath: path) { fh.seekToEndOfFile(); fh.write(d); fh.closeFile() }
        else { try? d.write(to: URL(fileURLWithPath: path), options: .atomic) }
    }

    private func sendNotification(title: String, message: String) {
        let t = title.replacingOccurrences(of: "\"", with: "\\\"")
        let m = message.replacingOccurrences(of: "\"", with: "\\\"")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", "display notification \"\(m)\" with title \"\(t)\""]
        try? proc.run()
    }
}

// MARK: - AppDelegate (Menu Bar + Watcher)

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var statusMenuItem: NSMenuItem!
    var watcher: FileWatcher?
    var processor: ClipProcessor!
    var existingFiles: Set<String> = []
    var isRunning = false
    var lastLink: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        
        guard Config.load() else {
            showError("Configuration not found. Run: clip setup")
            NSApp.terminate(nil)
            return
        }
        
        processor = ClipProcessor()
        processor.onStatusChange = { [weak self] in self?.updateStatus() }
        
        setupStatusBar()
        startWatcher()
    }

    func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.title = "⏹ Clip"
        }
        
        let menu = NSMenu()
        
        statusMenuItem = NSMenuItem(title: "Status: Starting...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Copy Last Link", action: #selector(copyLastLink), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: "Tail Log", action: #selector(tailLog), keyEquivalent: "l"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Restart", action: #selector(restartWatcher), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem.menu = menu
    }

    func startWatcher() {
        let watchDir = NSString(string: Config.file.watchDir).expandingTildeInPath
        
        // Snapshot existing files
        if let items = try? FileManager.default.contentsOfDirectory(atPath: watchDir) {
            existingFiles = Set(items)
            Logger.shared.info("Ignoring \(existingFiles.count) existing files")
        }
        
        try? FileManager.default.createDirectory(atPath: Config.tempDir, withIntermediateDirectories: true)
        try? "\(ProcessInfo.processInfo.processIdentifier)".write(toFile: Config.pidFile, atomically: true, encoding: .utf8)
        
        // Test connection
        Task {
            if let nc = processor.nextcloud {
                let ok = await nc.testConnection()
                if ok {
                    Logger.shared.ok("Nextcloud connection OK")
                } else {
                    Logger.shared.error("Nextcloud connection failed")
                }
            }
        }
        
        // Start file watcher
        watcher = FileWatcher(path: watchDir) { [weak self] in self?.scan() }
        isRunning = true
        updateStatus()
        
        Logger.shared.info("Clip Watcher started — monitoring \(Config.file.watchDir)")
    }

    func scan() {
        let watchDir = NSString(string: Config.file.watchDir).expandingTildeInPath
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: watchDir) else { return }
        for item in items {
            guard !existingFiles.contains(item) else { continue }
            guard !item.hasPrefix(".") else { continue }
            let ext = (item as NSString).pathExtension.lowercased()
            guard Config.allExtensions.contains(ext) else { continue }
            guard !item.hasPrefix("encoded_"), !item.hasPrefix("remux_"), !item.contains("_exiftool_tmp") else { continue }
            let full = "\(watchDir)/\(item)"
            Logger.shared.info("New clip detected: \(item)")
            processor.process(file: full)
        }
    }

    func updateStatus() {
        if let button = statusItem.button {
            button.title = isRunning ? "▶ Clip" : "⏹ Clip"
        }
        
        let recentUploads = getRecentUploads()
        if let last = recentUploads.first {
            statusMenuItem.title = "Last: \(last.1)"
            lastLink = last.0
        } else {
            statusMenuItem.title = isRunning ? "Status: Watching" : "Status: Stopped"
        }
    }

    func getRecentUploads() -> [(String, String)] {
        guard let content = try? String(contentsOfFile: Config.urlLog, encoding: .utf8) else { return [] }
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return lines.suffix(5).compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3 else { return nil }
            return (parts[1], parts[2])
        }
    }

    @objc func copyLastLink() {
        if let link = lastLink {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
            notify("Link Copied", link)
        } else {
            notify("No Links", "No uploads recorded yet")
        }
    }

    @objc func tailLog() {
        if FileManager.default.fileExists(atPath: Config.logFile) {
            NSWorkspace.shared.open(URL(fileURLWithPath: Config.logFile))
        }
    }

    @objc func restartWatcher() {
        watcher = nil
        existingFiles = []
        startWatcher()
    }

    @objc func quitApp() {
        try? FileManager.default.removeItem(atPath: Config.pidFile)
        NSApplication.shared.terminate(nil)
    }

    func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Clip Watcher Error"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
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

// MARK: - Setup Command

func runSetup() {
    print("Setting up clip-watcher configuration...")
    print("")
    
    var config = ConfigFile.default
    
    print("Watch directory [\(config.watchDir)]: ", terminator: "")
    if let input = readLine(), !input.isEmpty { config.watchDir = input }
    
    print("Nextcloud URL [\(config.nextcloudURL)]: ", terminator: "")
    if let input = readLine(), !input.isEmpty { config.nextcloudURL = input }
    
    print("Nextcloud username: ", terminator: "")
    if let input = readLine() { config.nextcloudUser = input }
    
    print("Nextcloud password: ", terminator: "")
    if let input = readLine() { config.nextcloudPass = input }
    
    print("ncembed domain [\(config.ncembedDomain)]: ", terminator: "")
    if let input = readLine(), !input.isEmpty { config.ncembedDomain = input }
    
    print("Use ncembed links? (y/n) [y]: ", terminator: "")
    if let input = readLine() { config.useNcembed = input.lowercased() != "n" }
    
    print("Samba shares (mount:path pairs, comma-separated, or empty) []: ", terminator: "")
    if let input = readLine(), !input.isEmpty {
        config.sambaShares = input.components(separatedBy: ",").compactMap { pair in
            let parts = pair.trimmingCharacters(in: .whitespaces).components(separatedBy: ":")
            guard parts.count == 2 else { return nil }
            return SambaShare(mountPath: parts[0].trimmingCharacters(in: .whitespaces),
                            nextcloudPath: parts[1].trimmingCharacters(in: .whitespaces))
        }
    }
    
    do {
        try Config.save(config)
        print("")
        print("Configuration saved to: \(Config.configFile)")
        print("Run 'clip' to start watching")
    } catch {
        print("Error saving config: \(error)")
        exit(1)
    }
    exit(0)
}

// MARK: - Main

let args = CommandLine.arguments
if args.count > 1 && args[1] == "setup" {
    runSetup()
}

// Check for existing instance
if let pidStr = try? String(contentsOfFile: Config.pidFile, encoding: .utf8),
   let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)),
   kill(pid, 0) == 0 {
    print("Clip Watcher is already running (PID \(pid))")
    print("Use 'clip stop' to stop it first")
    exit(1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
