import Foundation

enum HistoryLearning: Codable, Equatable {
    case watching, unconfirmed, noChange, saveFailed
    case candidate(String), learned(LearnedSpellingPreference), alreadyKnown(String), undone(String)

    var label: String {
        switch self {
        case .watching: return "正在等待修改"
        case .unconfirmed: return "未确认输入位置"
        case .noChange: return "未学到新拼写"
        case .saveFailed: return "拼写未能保存"
        case .candidate(let term): return "待确认 · " + term
        case .learned(let preference): return "已记住 · " + preference.phrase
        case .alreadyKnown(let term): return "已在词典 · " + term
        case .undone(let term): return "已撤销 · " + term
        }
    }
}

/// Logs all transcription results for offline analysis and prompt evolution.
/// Saves audio files + metadata to ~/.config/typefish/logs/
enum TranscriptionLogger {
    struct HistoryEntry: Equatable {
        var id: UUID? = nil
        var learning: HistoryLearning? = nil
        let timestamp: String
        let mode: String
        let whisperRaw: String
        let polished: String
        let whisperModel: String
        let polisherModel: String
        let audioFile: String
        let uploadFile: String
        let fieldContext: String

        var displayMode: String {
            switch mode {
            case "command": return "Command"
            case "translate": return "Translate"
            default: return "Dictation"
            }
        }

        var preview: String {
            let primary = polished.trimmingCharacters(in: .whitespacesAndNewlines)
            if !primary.isEmpty { return primary }
            return whisperRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var contextPreview: String {
            fieldContext.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    
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

    static let didChange = Notification.Name("TypeFishHistoryChanged")
    private static let runID = UUID()
    private static let lock = NSLock()
    private struct LearningEvent: Codable {
        let id: UUID
        let run: UUID
        let result: HistoryLearning
    }

    static func recordLearning(_ result: HistoryLearning, for id: UUID) {
        let event = LearningEvent(id: id, run: runID, result: result)
        guard let data = try? JSONEncoder().encode(event) else { return }
        append(data, to: logsDir.appendingPathComponent("learning.jsonl"))
    }

    private static func append(_ data: Data, to file: URL) {
        lock.lock()
        defer { lock.unlock() }
        do {
            if !FileManager.default.fileExists(atPath: file.path) {
                try Data().write(to: file)
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data + Data([0x0a]))
            DispatchQueue.main.async { NotificationCenter.default.post(name: didChange, object: nil) }
        } catch {
            Log.info("Could not save transcript history: " + error.localizedDescription)
        }
    }

    static func savedAudio(for entry: HistoryEntry) -> URL? {
        guard entry.mode != "command" else { return nil }
        // Use the original upload when retained so replay sees identical audio bytes.
        for name in [entry.uploadFile, entry.audioFile] where !name.isEmpty {
            guard (name as NSString).lastPathComponent == name,
                  ["wav", "m4a"].contains((name as NSString).pathExtension.lowercased()) else { continue }
            let url = audioDir.appendingPathComponent(name)
            if FileManager.default.isReadableFile(atPath: url.path) { return url }
        }
        return nil
    }

    static func recentHistory(limit: Int = 50) -> [HistoryEntry] {
        guard let content = try? String(contentsOf: logFile, encoding: .utf8) else { return [] }
        let events = (try? Data(contentsOf: logsDir.appendingPathComponent("learning.jsonl"))) ?? Data()
        return parseHistory(from: content, limit: limit, events: events)
    }

    static func parseHistory(from content: String, limit: Int, events: Data = Data()) -> [HistoryEntry] {
        guard limit > 0 else { return [] }
        let entries = content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .reversed()
            .compactMap { parseHistoryLine(String($0)) }
            .sorted { $0.timestamp > $1.timestamp }

        var rows = Array(entries.prefix(limit))
        let ids = Set(rows.compactMap(\.id))
        var results: [UUID: HistoryLearning] = [:]
        let decoder = JSONDecoder()
        for line in events.split(separator: 0x0a).reversed() {
            guard results.count < ids.count else { break }
            guard let event = try? decoder.decode(LearningEvent.self, from: Data(line)),
                  ids.contains(event.id), results[event.id] == nil else { continue }
            results[event.id] = event.result == .watching && event.run != runID ? .noChange : event.result
        }
        for index in rows.indices {
            rows[index].learning = rows[index].id.flatMap { results[$0] } ?? rows[index].learning
        }
        return rows
    }

    private static func parseHistoryLine(_ line: String) -> HistoryEntry? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timestamp = json["timestamp"] as? String else {
            return nil
        }

        let id = (json["id"] as? String).flatMap(UUID.init(uuidString:))
        return HistoryEntry(
            id: id,
            learning: id == nil || json["mode"] as? String == "command" ? nil : .unconfirmed,
            timestamp: timestamp,
            mode: json["mode"] as? String ?? "transcribe",
            whisperRaw: json["whisper_raw"] as? String ?? "",
            polished: json["polished"] as? String ?? "",
            whisperModel: json["whisper_model"] as? String ?? "",
            polisherModel: json["polisher_model"] as? String ?? "",
            audioFile: json["audio_file"] as? String ?? "",
            uploadFile: json["upload_file"] as? String ?? "",
            fieldContext: json["field_context"] as? String ?? ""
        )
    }
    
    /// Log a transcription result and preserve the audio file
    static func log(
        id: UUID = UUID(),
        audioURL: URL,
        uploadURL: URL? = nil,
        whisperRaw: String,
        polished: String,
        mode: String,  // "transcribe" or "translate"
        whisperModel: String,
        polisherModel: String,
        durationMs: Int? = nil,
        fieldContext: String? = nil
    ) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let audioFilename = audioURL.lastPathComponent
        
        // Copy audio to logs dir (before it gets cleaned up)
        let savedAudioURL = audioDir.appendingPathComponent(audioFilename)
        try? FileManager.default.copyItem(at: audioURL, to: savedAudioURL)
        
        var uploadFilename = ""
        if let uploadURL {
            uploadFilename = uploadURL.lastPathComponent
            if uploadURL != audioURL {
                let savedUploadURL = audioDir.appendingPathComponent(uploadFilename)
                try? FileManager.default.removeItem(at: savedUploadURL)
                try? FileManager.default.copyItem(at: uploadURL, to: savedUploadURL)
            }
        }
        
        // Build log entry
        let entry: [String: Any] = [
            "id": id.uuidString,
            "timestamp": timestamp,
            "audio_file": audioFilename,
            "upload_file": uploadFilename,
            "whisper_raw": whisperRaw,
            "polished": polished,
            "mode": mode,
            "whisper_model": whisperModel,
            "polisher_model": polisherModel,
            "duration_ms": durationMs ?? 0,
            "typeless_result": "",  // filled later via comparison tool
            "field_context": fieldContext ?? ""
        ]
        
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        append(data, to: logFile)
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
