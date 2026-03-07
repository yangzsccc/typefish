import Foundation

/// Logs all transcription results for offline analysis and prompt evolution.
/// Saves audio files + metadata to ~/.config/typefish/logs/
enum TranscriptionLogger {
    
    private static let logsDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/typefish/logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    
    private static let logFile: URL = {
        return logsDir.appendingPathComponent("transcriptions.jsonl")
    }()
    
    private static let audioDir: URL = {
        let dir = logsDir.appendingPathComponent("audio")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    
    /// Log a transcription result and preserve the audio file
    static func log(
        audioURL: URL,
        whisperRaw: String,
        polished: String,
        mode: String,  // "transcribe" or "translate"
        whisperModel: String,
        polisherModel: String,
        durationMs: Int? = nil
    ) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let audioFilename = audioURL.lastPathComponent
        
        // Copy audio to logs dir (before it gets cleaned up)
        let savedAudioURL = audioDir.appendingPathComponent(audioFilename)
        try? FileManager.default.copyItem(at: audioURL, to: savedAudioURL)
        
        // Build log entry
        let entry: [String: Any] = [
            "timestamp": timestamp,
            "audio_file": audioFilename,
            "whisper_raw": whisperRaw,
            "polished": polished,
            "mode": mode,
            "whisper_model": whisperModel,
            "polisher_model": polisherModel,
            "duration_ms": durationMs ?? 0,
            "typeless_result": ""  // filled later via comparison tool
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
              var jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }
        jsonString += "\n"
        
        // Append to JSONL
        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            handle.write(jsonString.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? jsonString.data(using: .utf8)?.write(to: logFile)
        }
    }
    
    /// Clean up audio files older than N days
    static func cleanOldFiles(daysToKeep: Int = 7) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(daysToKeep * 86400))
        
        guard let files = try? fm.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: [.creationDateKey]) else {
            return
        }
        
        var removed = 0
        for file in files {
            if let attrs = try? file.resourceValues(forKeys: [.creationDateKey]),
               let created = attrs.creationDate,
               created < cutoff {
                try? fm.removeItem(at: file)
                removed += 1
            }
        }
        
        if removed > 0 {
            Log.info("🧹 Cleaned \(removed) old audio logs")
        }
    }
}
