import Foundation

/// Structured pipeline metrics for health monitoring.
/// Writes to ~/.config/typefish/logs/metrics.jsonl
enum MetricsLogger {
    
    private static let metricsPath: String = {
        let dir = NSHomeDirectory() + "/.config/typefish/logs"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/metrics.jsonl"
    }()
    
    struct PipelineMetrics {
        var timestamp: String = ISO8601DateFormatter().string(from: Date())
        var mode: String = "transcribe"  // transcribe, translate, command
        var audioSizeKB: Int = 0
        var whisperTimeMs: Int = 0
        var polishTimeMs: Int = 0
        var totalTimeMs: Int = 0
        var success: Bool = true
        var errorType: String? = nil     // "whisper_timeout", "rate_limit", "api_error", etc.
        var errorDetail: String? = nil
        var whisperModel: String = ""
        var polishModel: String = ""
        var wasFallback: Bool = false     // polisher used fallback model
        var wasRetry: Bool = false        // whisper was retried
    }

    struct Stats: Equatable {
        var total: Int = 0
        var success: Int = 0
        var errors: [String: Int] = [:]
        var avgWhisperMs: Int = 0
        var avgPolishMs: Int = 0
        var avgTotalMs: Int = 0

        var successRate: Int {
            total > 0 ? Int(Double(success) / Double(total) * 100) : 0
        }
    }
    
    static func log(_ metrics: PipelineMetrics) {
        var dict: [String: Any] = [
            "t": metrics.timestamp,
            "mode": metrics.mode,
            "audio_kb": metrics.audioSizeKB,
            "whisper_ms": metrics.whisperTimeMs,
            "polish_ms": metrics.polishTimeMs,
            "total_ms": metrics.totalTimeMs,
            "ok": metrics.success,
        ]
        if let e = metrics.errorType { dict["err"] = e }
        if let d = metrics.errorDetail { dict["err_detail"] = String(d.prefix(200)) }
        if !metrics.whisperModel.isEmpty { dict["w_model"] = metrics.whisperModel }
        if !metrics.polishModel.isEmpty { dict["p_model"] = metrics.polishModel }
        if metrics.wasFallback { dict["fallback"] = true }
        if metrics.wasRetry { dict["retry"] = true }
        
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        
        if let lineData = line.data(using: .utf8) {
            if let handle = FileHandle(forWritingAtPath: metricsPath) {
                handle.seekToEndOfFile()
                handle.write(lineData)
                handle.closeFile()
            } else {
                FileManager.default.createFile(atPath: metricsPath, contents: lineData)
            }
        }
    }
    
    /// Read recent metrics for health display
    static func recentStats(hours: Int = 24) -> Stats {
        guard let content = try? String(contentsOfFile: metricsPath, encoding: .utf8) else {
            return Stats()
        }

        return analyze(content: content, now: Date(), hours: hours)
    }

    static func analyze(content: String, now: Date, hours: Int = 24) -> Stats {
        let cutoff = now.addingTimeInterval(-Double(hours * 3600))
        let isoFormatter = ISO8601DateFormatter()

        var total = 0, success = 0
        var errors: [String: Int] = [:]
        var whisperTimes: [Int] = []
        var polishTimes: [Int] = []
        var totalTimes: [Int] = []

        for line in content.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ts = dict["t"] as? String,
                  let date = isoFormatter.date(from: ts),
                  date >= cutoff else { continue }

            total += 1
            if dict["ok"] as? Bool == true {
                success += 1
            }
            if let err = dict["err"] as? String {
                errors[err, default: 0] += 1
            }
            if let wt = dict["whisper_ms"] as? Int, wt > 0 { whisperTimes.append(wt) }
            if let pt = dict["polish_ms"] as? Int, pt > 0 { polishTimes.append(pt) }
            if let tt = dict["total_ms"] as? Int, tt > 0 { totalTimes.append(tt) }
        }

        let avgW = whisperTimes.isEmpty ? 0 : whisperTimes.reduce(0, +) / whisperTimes.count
        let avgP = polishTimes.isEmpty ? 0 : polishTimes.reduce(0, +) / polishTimes.count
        let avgT = totalTimes.isEmpty ? 0 : totalTimes.reduce(0, +) / totalTimes.count

        return Stats(
            total: total,
            success: success,
            errors: errors,
            avgWhisperMs: avgW,
            avgPolishMs: avgP,
            avgTotalMs: avgT
        )
    }
}
