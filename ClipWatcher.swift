#!/usr/bin/swift

import Cocoa
import Foundation
import System

// MARK: - Configuration

struct Config {
    // Directories
    static let watchDir = NSString("~/Movies/Captures/optimised").expandingTildeInPath
    static let tempDir = NSString("~/Movies/Captures/encoded").expandingTildeInPath
    static let logFile = "\(tempDir)/clip-watcher.log"
    static let pidFile = "\(tempDir)/.clip-watcher.pid"
    static let urlLog = "\(tempDir)/.urls"
    static let processedLog = "\(tempDir)/.processed"
    
    // Nextcloud
    static let nextcloudURL = "https://save.mudbourn.info"
    static let nextcloudUser = "" // Set via NC_USER env var
    static let nextcloudPass = "" // Set via NC_PASS env var
    static let uploadPath = "/Videos/clips"
    
    // Samba shares
    static let sambaShares = [
        "/Volumes/UGREENNVME-Share/nextcloud",
        "/Volumes/ToshibaHD-Share/nextcloud"
    ]
    
    // ncembed
    static let ncembedDomain = "share.mudbourn.info"
    
    // Processing
    static let sizeLimitMB = 24
    static let sizeLimit = sizeLimitMB * 1024 * 1024
    static let stableChecks = 3
    static let stableInterval: TimeInterval = 2.0
    
    // File extensions
    static let videoExtensions: Set<String> = ["mp4", "mkv", "mov", "avi", "webm"]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff"]
    static let allExtensions: Set<String> = videoExtensions.union(imageExtensions)
    
    // Link behavior
    static let useNcembed = true
}

// MARK: - Logger

class Logger {
    static let shared = Logger()
    private let logQueue = DispatchQueue(label: "com.clip-watcher.logger", qos: .utility)
    private let dateFormatter: DateFormatter
    
    init() {
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    }
    
    func log(_ level: String, _ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let logMessage = "[\(timestamp)] [\(level)] \(message)"
        
        logQueue.async {
            print(logMessage)
            self.appendToLogFile(logMessage)
        }
    }
    
    func info(_ message: String) { log("INFO ", message) }
    func ok(_ message: String) { log(" OK  ", message) }
    func warn(_ message: String) { log("WARN ", message) }
    func error(_ message: String) { log("ERROR", message) }
    func debug(_ message: String) { log("DEBUG", message) }
    
    func separator() {
        log("", "──────────────────────────────────────────────────────────")
    }
    
    private func appendToLogFile(_ message: String) {
        guard let data = (message + "\n").data(using: .utf8) else { return }
        
        if FileManager.default.fileExists(atPath: Config.logFile) {
            if let fileHandle = FileHandle(forWritingAtPath: Config.logFile) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                fileHandle.closeFile()
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: Config.logFile), options: .atomic)
        }
    }
}

// MARK: - NextcloudClient

class NextcloudClient {
    private let session: URLSession
    private let baseURL: URL
    private let credentials: String
    
    init?() {
        let user = ProcessInfo.processInfo.environment["NC_USER"] ?? Config.nextcloudUser
        let pass = ProcessInfo.processInfo.environment["NC_PASS"] ?? Config.nextcloudPass
        
        guard !user.isEmpty, !pass.isEmpty else {
            Logger.shared.error("Nextcloud credentials not set")
            return nil
        }
        
        guard let url = URL(string: Config.nextcloudURL) else {
            Logger.shared.error("Invalid Nextcloud URL: \(Config.nextcloudURL)")
            return nil
        }
        
        self.baseURL = url
        self.credentials = "\(user):\(pass)"
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }
    
    private func authHeader() -> String {
        let data = credentials.data(using: .utf8)!
        return "Basic \(data.base64EncodedString())"
    }
    
    func testConnection() async -> Bool {
        let url = baseURL.appendingPathComponent("ocs/v2.php/cloud/user")
        var request = URLRequest(url: url)
        request.setValue(authHeader(), forHTTPHeaderField: "Authorization")
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
    
    func upload(file: String, to remotePath: String) async -> Bool {
        let fileURL = URL(fileURLWithPath: file)
        let fileName = fileURL.lastPathComponent
        let remoteURL = baseURL.appendingPathComponent("dav/files/\(Config.nextcloudUser)\(remotePath)/\(fileName)")
        
        // Create directory if needed
        let dirURL = baseURL.appendingPathComponent("dav/files/\(Config.nextcloudUser)\(remotePath)")
        var dirRequest = URLRequest(url: dirURL)
        dirRequest.httpMethod = "MKCOL"
        dirRequest.setValue(authHeader(), forHTTPHeaderField: "Authorization")
        _ = try? await session.data(for: dirRequest)
        
        // Upload file
        var request = URLRequest(url: remoteURL)
        request.httpMethod = "PUT"
        request.setValue(authHeader(), forHTTPHeaderField: "Authorization")
        
        do {
            let fileData = try Data(contentsOf: fileURL)
            let (_, response) = try await session.upload(for: request, from: fileData)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            return statusCode >= 200 && statusCode < 300
        } catch {
            Logger.shared.error("Upload failed: \(error)")
            return false
        }
    }
    
    func createShare(filePath: String) async -> String? {
        let url = baseURL.appendingPathComponent("ocs/v2.php/apps/files_sharing/api/v1/shares")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(authHeader(), forHTTPHeaderField: "Authorization")
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let body = "path=\(filePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filePath)&shareType=3&permissions=1"
        request.httpBody = body.data(using: .utf8)
        
        do {
            let (data, _) = try await session.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let ocs = json?["ocs"] as? [String: Any]
            let meta = ocs?["meta"] as? [String: Any]
            let statusCode = meta?["statuscode"] as? Int ?? 0
            
            if statusCode == 100 {
                let shareData = ocs?["data"] as? [String: Any]
                return shareData?["token"] as? String
            }
        } catch {
            Logger.shared.error("Create share failed: \(error)")
        }
        return nil
    }
}

// MARK: - SambaManager

class SambaManager {
    static func findAvailableShare() -> String? {
        for share in Config.sambaShares {
            if FileManager.default.fileExists(atPath: share) {
                return share
            }
        }
        return nil
    }
    
    static func copy(file: String, to sambaRoot: String, remotePath: String) -> Bool {
        let fileURL = URL(fileURLWithPath: file)
        let fileName = fileURL.lastPathComponent
        let destDir = "\(sambaRoot)\(remotePath)"
        let destFile = "\(destDir)/\(fileName)"
        
        do {
            try FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: file, toPath: destFile)
            return true
        } catch {
            Logger.shared.error("Samba copy failed: \(error)")
            return false
        }
    }
}

// MARK: - ClipboardManager

class ClipboardManager {
    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
    
    static func getClipboard() -> String? {
        return NSPasteboard.general.string(forType: .string)
    }
}

// MARK: - FileWatcher

class FileWatcher {
    private var stream: FSEventStreamRef?
    private let callback: (String) -> Void
    
    init(path: String, callback: @escaping (String) -> Void) {
        self.callback = callback
        startWatching(path: path)
    }
    
    deinit {
        stopWatching()
    }
    
    private func startWatching(path: String) {
        let pathsToWatch = [path] as CFArray
        
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        
        stream = FSEventStreamCreate(
            nil,
            { (stream, contextInfo, numEvents, eventPaths, eventFlags, eventIds) in
                guard let contextInfo = contextInfo else { return }
                let watcher = Unmanaged<FileWatcher>.fromOpaque(contextInfo).takeUnretainedValue()
                
                let paths = unsafeBitCast(eventPaths, to: NSArray.self) as! [String]
                
                for i in 0..<numEvents {
                    let flags = eventFlags[i]
                    let path = paths[i]
                    
                    // Only process file events (not directory events)
                    if flags & UInt32(kFSEventStreamItemFlagIsFile) != 0 {
                        // Check for rename/move events
                        if flags & UInt32(kFSEventStreamItemFlagItemRenamed) != 0 ||
                           flags & UInt32(kFSEventStreamItemFlagItemModified) != 0 {
                            watcher.callback(path)
                        }
                    }
                }
            },
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0, // Latency in seconds
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        )
        
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream!)
    }
    
    private func stopWatching() {
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

// MARK: - ClipProcessor

class ClipProcessor {
    private let nextcloud: NextcloudClient?
    private let processingQueue = DispatchQueue(label: "com.clip-watcher.processor", qos: .userInitiated, attributes: .concurrent)
    private var processedFiles: Set<String> = []
    private var inFlightFiles: Set<String> = []
    private let lock = NSLock()
    
    init() {
        self.nextcloud = NextcloudClient()
        loadProcessedFiles()
    }
    
    private func loadProcessedFiles() {
        guard let data = FileManager.default.contents(atPath: Config.processedLog),
              let content = String(data: data, encoding: .utf8) else { return }
        
        let files = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        processedFiles = Set(files)
    }
    
    func process(file: String) {
        lock.lock()
        defer { lock.unlock() }
        
        // Skip if already processed or in-flight
        if processedFiles.contains(file) || inFlightFiles.contains(file) {
            return
        }
        
        // Mark as in-flight
        inFlightFiles.insert(file)
        
        processingQueue.async { [weak self] in
            self?.processFile(file)
        }
    }
    
    private func processFile(_ file: String) {
        let fileName = (file as NSString).lastPathComponent
        
        Logger.shared.info("[\(fileName)] Processing started")
        Logger.shared.info("[\(fileName)] Waiting for file to stabilize...")
        
        // Wait for file to stabilize
        guard waitForFileToStabilize(file) else {
            Logger.shared.error("[\(fileName)] File never stabilized, skipping")
            removeInFlight(file)
            return
        }
        
        let fileSize = fileSize(file)
        Logger.shared.info("[\(fileName)] File ready: \(fileSize / 1024 / 1024)MB")
        
        // Upload and share
        Task {
            let success = await uploadAndShare(file: file)
            
            if success {
                // Mark as processed
                lock.lock()
                processedFiles.insert(file)
                inFlightFiles.remove(file)
                lock.unlock()
                
                // Append to processed log
                appendToFile(Config.processedLog, content: file + "\n")
                
                Logger.shared.ok("[\(fileName)] Done")
                Logger.shared.separator()
            } else {
                removeInFlight(file)
            }
        }
    }
    
    private func waitForFileToStabilize(_ file: String) -> Bool {
        var stableCount = 0
        var previousSize = fileSize(file)
        
        for _ in 0..<30 {
            Thread.sleep(forTimeInterval: Config.stableInterval)
            let currentSize = fileSize(file)
            
            if currentSize == previousSize && currentSize > 0 {
                stableCount += 1
                if stableCount >= Config.stableChecks {
                    return true
                }
            } else {
                stableCount = 0
            }
            
            previousSize = currentSize
        }
        
        return false
    }
    
    private func uploadAndShare(file: String) async -> Bool {
        let fileName = (file as NSString).lastPathComponent
        let fileSize = fileSize(file)
        
        Logger.shared.info("Uploading: \(fileName) (\(fileSize / 1024 / 1024)MB)")
        
        // Try Samba first
        var uploadMethod = "webdav"
        if let sambaRoot = SambaManager.findAvailableShare() {
            Logger.shared.info("Using Samba share: \(sambaRoot)")
            if SambaManager.copy(file: file, to: sambaRoot, remotePath: Config.uploadPath) {
                uploadMethod = "samba"
                Logger.shared.ok("Copied to Samba: \(sambaRoot)\(Config.uploadPath)/\(fileName)")
            } else {
                Logger.shared.warn("Samba copy failed, falling back to WebDAV")
            }
        }
        
        // Fall back to WebDAV if needed
        if uploadMethod == "webdav" {
            guard let nextcloud = nextcloud else {
                Logger.shared.error("Nextcloud client not available")
                return false
            }
            
            let success = await nextcloud.upload(file: file, to: Config.uploadPath)
            if success {
                Logger.shared.ok("Uploaded via WebDAV: \(Config.uploadPath)/\(fileName)")
            } else {
                Logger.shared.error("Upload failed for \(fileName)")
                return false
            }
        }
        
        // Create share link
        guard let nextcloud = nextcloud else { return false }
        guard let token = await nextcloud.createShare(filePath: "\(Config.uploadPath)/\(fileName)") else {
            Logger.shared.error("Failed to create share for \(fileName)")
            return false
        }
        
        // Generate share URL
        let shareURL: String
        if Config.useNcembed {
            shareURL = "https://\(Config.ncembedDomain)/embed/\(token)"
        } else {
            shareURL = "\(Config.nextcloudURL)/s/\(token)"
        }
        
        // Copy to clipboard
        ClipboardManager.copyToClipboard(shareURL)
        
        // Log URL
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
        appendToFile(Config.urlLog, content: "\(timestamp)\t\(shareURL)\t\(fileName)\n")
        
        Logger.shared.ok("Link copied: \(shareURL)")
        
        // Send notification
        sendNotification(title: "Clip Ready", message: shareURL)
        
        return true
    }
    
    private func removeInFlight(_ file: String) {
        lock.lock()
        inFlightFiles.remove(file)
        lock.unlock()
    }
    
    private func fileSize(_ file: String) -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file) else { return 0 }
        return attrs[.size] as? Int ?? 0
    }
    
    private func appendToFile(_ file: String, content: String) {
        guard let data = content.data(using: .utf8) else { return }
        
        if FileManager.default.fileExists(atPath: file) {
            if let fileHandle = FileHandle(forWritingAtPath: file) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                fileHandle.closeFile()
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: file), options: .atomic)
        }
    }
    
    private func sendNotification(title: String, message: String) {
        DispatchQueue.main.async {
            let notification = NSUserNotification()
            notification.title = title
            notification.informativeText = message
            notification.soundName = NSUserNotificationDefaultSoundName
            NSUserNotificationCenter.default.deliver(notification)
        }
    }
}

// MARK: - ClipWatcher

class ClipWatcher {
    private var fileWatcher: FileWatcher?
    private let processor: ClipProcessor
    private var isRunning = false
    
    init() {
        self.processor = ClipProcessor()
    }
    
    func start() async {
        guard !isRunning else {
            Logger.shared.warn("Clip-watcher is already running")
            return
        }
        
        Logger.shared.separator()
        Logger.shared.info("clip-watcher starting")
        Logger.shared.info("Watching: \(Config.watchDir)")
        Logger.shared.info("Temp dir: \(Config.tempDir)")
        Logger.shared.info("Nextcloud: \(Config.nextcloudURL)")
        Logger.shared.info("Upload path: \(Config.uploadPath)")
        Logger.shared.info("ncembed: \(Config.ncembedDomain)")
        
        // Check Samba shares
        if let sambaRoot = SambaManager.findAvailableShare() {
            Logger.shared.ok("Samba share available: \(sambaRoot)")
        } else {
            Logger.shared.warn("No Samba shares mounted (will use WebDAV fallback)")
        }
        
        Logger.shared.info("Size limit: \(Config.sizeLimitMB)MB")
        Logger.shared.separator()
        
        // Test Nextcloud connection
        if let nextcloud = processor.nextcloud {
            Logger.shared.info("Testing Nextcloud connection...")
            let connected = await nextcloud.testConnection()
            if connected {
                Logger.shared.ok("Nextcloud connection OK")
            } else {
                Logger.shared.error("Nextcloud connection failed")
                return
            }
        }
        
        // Create directories
        try? FileManager.default.createDirectory(atPath: Config.tempDir, withIntermediateDirectories: true)
        
        // Write PID file
        writePIDFile()
        
        // Start file watcher
        fileWatcher = FileWatcher(path: Config.watchDir) { [weak self] filePath in
            self?.handleFileEvent(filePath)
        }
        
        isRunning = true
        Logger.shared.info("File watcher started")
        
        // Keep running
        RunLoop.main.run()
    }
    
    func stop() {
        fileWatcher = nil
        isRunning = false
        removePIDFile()
        Logger.shared.info("clip-watcher stopped")
        Logger.shared.separator()
    }
    
    private func handleFileEvent(_ filePath: String) {
        let fileName = (filePath as NSString).lastPathComponent
        let fileExtension = (filePath as NSString).pathExtension.lowercased()
        
        // Skip if not a supported file type
        guard Config.allExtensions.contains(fileExtension) else { return }
        
        // Skip temp directory files
        if filePath.hasPrefix(Config.tempDir) { return }
        
        // Skip encoded/remux files
        if fileName.hasPrefix("encoded_") || fileName.hasPrefix("remux_") { return }
        
        // Skip exiftool temp files
        if fileName.contains("_exiftool_tmp") { return }
        
        Logger.shared.info("New clip detected: \(fileName)")
        processor.process(file: filePath)
    }
    
    private func writePIDFile() {
        let pid = ProcessInfo.processInfo.processIdentifier
        try? "\(pid)".write(toFile: Config.pidFile, atomically: true, encoding: .utf8)
    }
    
    private func removePIDFile() {
        try? FileManager.default.removeItem(atPath: Config.pidFile)
    }
}

// MARK: - Main

let watcher = ClipWatcher()

// Handle signals for graceful shutdown
signal(SIGINT) { _ in
    watcher.stop()
    exit(0)
}

signal(SIGTERM) { _ in
    watcher.stop()
    exit(0)
}

// Start the watcher
Task {
    await watcher.start()
}
