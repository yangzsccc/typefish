import Foundation

/// Simple file logger → /tmp/typefish.log (keeps previous session in .prev)
enum Log {
    private static let logPath = "/tmp/typefish.log"
    private static let prevLogPath = "/tmp/typefish.log.prev"
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    
    /// Rotate: move current log to .prev, start fresh
    static func rotate() {
        let fm = FileManager.default
        try? fm.removeItem(atPath: prevLogPath)
        if fm.fileExists(atPath: logPath) {
            try? fm.moveItem(atPath: logPath, toPath: prevLogPath)
        }
    }
    
    @available(*, deprecated, renamed: "rotate")
    static func clear() {
        rotate()
    }
    
    static func info(_ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        print(line, terminator: "")
        
        if let data = line.data(using: .utf8) {
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                FileManager.default.createFile(atPath: logPath, contents: data)
            }
        }
    }
}
