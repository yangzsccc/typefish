import Foundation

/// Persistent file logger.
/// Writes to ~/.config/typefish/logs/app-YYYY-MM-DD.log (daily rotation, keeps 7 days)
/// Also writes to /tmp/typefish.log for quick access.
enum Log {
    private static let tmpLogPath = "/tmp/typefish.log"
    private static let prevLogPath = "/tmp/typefish.log.prev"
    
    private static let logsDir: String = {
        let dir = NSHomeDirectory() + "/.config/typefish/logs"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()
    
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    
    private static var currentDayPath: String {
        let day = dayFormatter.string(from: Date())
        return "\(logsDir)/app-\(day).log"
    }
    
    /// Rotate tmp log (keep .prev for backward compat) + clean old daily logs
    static func rotate() {
        let fm = FileManager.default
        try? fm.removeItem(atPath: prevLogPath)
        if fm.fileExists(atPath: tmpLogPath) {
            try? fm.moveItem(atPath: tmpLogPath, toPath: prevLogPath)
        }
        cleanOldLogs()
    }
    
    /// Remove daily logs older than 7 days
    static func cleanOldLogs() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: logsDir) else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        
        for file in files {
            guard file.hasPrefix("app-") && file.hasSuffix(".log") else { continue }
            let dateStr = String(file.dropFirst(4).dropLast(4))  // "app-YYYY-MM-DD.log" → "YYYY-MM-DD"
            if let fileDate = dayFormatter.date(from: dateStr), fileDate < cutoff {
                try? fm.removeItem(atPath: "\(logsDir)/\(file)")
            }
        }
    }
    
    static func info(_ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        print(line, terminator: "")
        
        if let data = line.data(using: .utf8) {
            // Write to /tmp for quick access
            appendToFile(data, path: tmpLogPath)
            // Write to persistent daily log
            appendToFile(data, path: currentDayPath)
        }
    }
    
    private static func appendToFile(_ data: Data, path: String) {
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}
