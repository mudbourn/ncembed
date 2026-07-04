#!/usr/bin/swift

import Cocoa
import Foundation

// MARK: - Configuration (loaded from JSON)

struct ConfigFile: Codable {
    var watchDir: String
    var nextcloudURL: String
    var nextcloudUser: String
    var nextcloudPass: String
    var uploadPath: String
    var ncembedDomain: String
    var useNcembed: Bool
    var sambaShares: [String]
    
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
        guard FileManager.default.fileExists(atPath: configFile) else {
            return false
        }
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
        let data = try JSONEncoder().encode(config)
        try data.write(to: URL(fileURLWithPath: configFile))
    }
}

// MARK: - Logger

class Logger {
    static let shared = Logger()
    private let queue = DispatchQueue(label: "com.clip-watcher.logger", qos: .utility)
    private let df = DateFormatter()

    init() { df.dateFormat = "yyyy-MM-dd HH:mm:ss" }

    func log(_ level: String, _ msg: String) {
        let ts = df.string(from: Date())
        let line = "[\(ts)] [\(level)] \(msg)"
        queue.async {
            print(line)
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

    func upload(file: String) async -> Bool {
        let name = (file as NSString).lastPathComponent
        let remote = baseURL.appendingPathComponent("dav/files/\(user)\(Config.file.uploadPath)/\(name)")
        let dir = baseURL.appendingPathComponent("dav/files/\(user)\(Config.file.uploadPath)")

        var mk = URLRequest(url: dir)
        mk.httpMethod = "MKCOL"
        mk.setValue(authValue(), forHTTPHeaderField: "Authorization")
        _ = try? await session.data(for: mk)

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)) else { return false }
        var req = URLRequest(url: remote)
        req.httpMethod = "PUT"
        req.setValue(authValue(), forHTTPHeaderField: "Authorization")
        guard let (_, resp) = try? await session.upload(for: req, from: data) else { return false }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return code >= 200 && code < 300
    }

    func createShare(filePath: String) async -> String? {
        let url = baseURL.appendingPathComponent("ocs/v2.php/apps/files_sharing/api/v1/shares")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(authValue(), forHTTPHeaderField: "Authorization")
        req.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "path=\(filePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filePath)&shareType=3&permissions=1".data(using: .utf8)

        guard let (data, _) = try? await session.data(for: req) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ocs = json["ocs"] as? [String: Any],
              let meta = ocs["meta"] as? [String: Any],
              meta["statuscode"] as? Int == 100,
              let d = ocs["data"] as? [String: Any],
              let token = d["token"] as? String else { return nil }
        return token
    }
}

// MARK: - FileWatcher using kqueue

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

            // Try Samba first
            var method = "webdav"
            if let samba = sambaRoot() {
                Logger.shared.info("Using Samba share: \(samba)")
                let dest = "\(samba)\(Config.file.uploadPath)/\(name)"
                let destDir = "\(samba)\(Config.file.uploadPath)"
                if (try? FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)) != nil,
                   (try? FileManager.default.copyItem(atPath: file, toPath: dest)) != nil {
                    method = "samba"
                    Logger.shared.ok("Copied to Samba: \(dest)")
                } else {
                    Logger.shared.warn("Samba copy failed, falling back to WebDAV")
                }
            }

            if method == "webdav" {
                let ok = await nc.upload(file: file)
                guard ok else {
                    Logger.shared.error("Upload failed for \(name)")
                    removeInFlight(file)
                    return
                }
                Logger.shared.ok("Uploaded via WebDAV: \(Config.file.uploadPath)/\(name)")
            }

            guard let token = await nc.createShare(filePath: "\(Config.file.uploadPath)/\(name)") else {
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

    private func sambaRoot() -> String? {
        Config.file.sambaShares.first { FileManager.default.fileExists(atPath: $0) }
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

// MARK: - ClipWatcher

class ClipWatcher {
    private var dirWatcher: FileWatcher?
    private let processor: ClipProcessor

    init() { processor = ClipProcessor() }

    func start() async {
        Logger.shared.separator()
        Logger.shared.info("clip-watcher starting")
        Logger.shared.info("Watching: \(Config.file.watchDir)")
        Logger.shared.info("Nextcloud: \(Config.file.nextcloudURL)")
        Logger.shared.info("ncembed: \(Config.file.ncembedDomain)")

        if let s = Config.file.sambaShares.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            Logger.shared.ok("Samba share available: \(s)")
        } else {
            Logger.shared.warn("No Samba shares mounted")
        }
        Logger.shared.separator()

        if let nc = processor.nextcloud {
            Logger.shared.info("Testing Nextcloud connection...")
            if await nc.testConnection() { Logger.shared.ok("Nextcloud connection OK") }
            else { Logger.shared.error("Nextcloud connection failed"); return }
        }

        let watchDir = NSString(string: Config.file.watchDir).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: Config.tempDir, withIntermediateDirectories: true)
        try? "\(ProcessInfo.processInfo.processIdentifier)".write(toFile: Config.pidFile, atomically: true, encoding: .utf8)

        dirWatcher = FileWatcher(path: watchDir) { [weak self] in self?.scan() }
        Logger.shared.info("File watcher started")

        while true { try? await Task.sleep(nanoseconds: 60_000_000_000) }
    }

    func stop() {
        dirWatcher = nil
        try? FileManager.default.removeItem(atPath: Config.pidFile)
        Logger.shared.info("clip-watcher stopped")
        Logger.shared.separator()
    }

    private func scan() {
        let watchDir = NSString(string: Config.file.watchDir).expandingTildeInPath
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: watchDir) else { return }
        for item in items {
            let ext = (item as NSString).pathExtension.lowercased()
            guard Config.allExtensions.contains(ext) else { continue }
            guard !item.hasPrefix("encoded_"), !item.hasPrefix("remux_"), !item.contains("_exiftool_tmp") else { continue }
            let full = "\(watchDir)/\(item)"
            Logger.shared.info("New clip detected: \(item)")
            processor.process(file: full)
        }
    }
}

// MARK: - Main

// Check for setup command
let args = CommandLine.arguments
if args.count > 1 && args[1] == "setup" {
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
    
    print("Upload path [\(config.uploadPath)]: ", terminator: "")
    if let input = readLine(), !input.isEmpty { config.uploadPath = input }
    
    print("ncembed domain [\(config.ncembedDomain)]: ", terminator: "")
    if let input = readLine(), !input.isEmpty { config.ncembedDomain = input }
    
    print("Use ncembed links? (y/n) [y]: ", terminator: "")
    if let input = readLine() { config.useNcembed = input.lowercased() != "n" }
    
    print("Samba shares (comma-separated, or empty) []: ", terminator: "")
    if let input = readLine(), !input.isEmpty {
        config.sambaShares = input.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }
    
    do {
        try Config.save(config)
        print("")
        print("Configuration saved to: \(Config.configFile)")
        print("Run 'clip start' to begin watching")
    } catch {
        print("Error saving config: \(error)")
        exit(1)
    }
    exit(0)
}

// Load config
guard Config.load() else {
    print("Error: Configuration not found. Run 'clip setup' first.")
    exit(1)
}

let watcher = ClipWatcher()

signal(SIGINT) { _ in watcher.stop(); exit(0) }
signal(SIGTERM) { _ in watcher.stop(); exit(0) }

Task {
    await watcher.start()
}

RunLoop.main.run()
