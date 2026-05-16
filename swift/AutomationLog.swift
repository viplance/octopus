import Foundation

// File-based logger for SmartThingsTokenAutomation. NSLog goes to the unified
// log which is hard to extract; this writes a plain rolling file at a known
// path so the developer can `tail` it during debug sessions.
//
// Path: ~/Library/Logs/OctopusSync/automation.log
// Truncates to last ~200 KB on each open to avoid unbounded growth.
enum AutomationLog {

    private static let queue = DispatchQueue(label: "enotix.OctopusSync.automation-log")

    nonisolated static let logFileURL: URL = {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/OctopusSync", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        return logsDir.appendingPathComponent("automation.log")
    }()

    nonisolated static func log(_ message: String) {
        queue.async {
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let line = "[\(timestamp)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }

            if !FileManager.default.fileExists(atPath: logFileURL.path) {
                try? data.write(to: logFileURL)
                return
            }

            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                defer { try? handle.close() }
                do {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } catch {
                    // Best-effort logger; if disk is full or file got moved
                    // we don't want to crash the calling automation.
                }
            }

            // Trim if file grows past ~200 KB. Keep tail half so we always
            // have the most recent run's logs intact.
            if let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
               let size = attrs[.size] as? UInt64, size > 200_000 {
                if let data = try? Data(contentsOf: logFileURL) {
                    let tail = data.suffix(100_000)
                    try? tail.write(to: logFileURL)
                }
            }
        }
    }
}
