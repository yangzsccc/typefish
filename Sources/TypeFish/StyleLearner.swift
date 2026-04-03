import Foundation

/// Tracks user's writing style preferences and builds a personalization profile.
/// Stored at ~/.config/typefish/style-profile.json
/// Used to give the polisher context about how the user writes.
class StyleLearner {
    
    static let shared = StyleLearner()
    
    private let profilePath: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/typefish")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("style-profile.json")
    }()
    
    struct StyleProfile: Codable {
        var totalDictations: Int = 0
        var totalCharsTranscribed: Int = 0
        var primaryLanguage: String = "auto"        // "zh", "en", "mixed"
        var recentExamples: [StyleExample] = []     // Last 10 good examples
        var commonPatterns: [String] = []            // Observed writing patterns
        var lastUpdated: String = ""
    }
    
    struct StyleExample: Codable {
        var raw: String       // Whisper output
        var polished: String  // Polished output (what user accepted)
        var app: String       // Which app it was used in
    }
    
    private(set) var profile: StyleProfile
    
    private init() {
        if let data = try? Data(contentsOf: profilePath),
           let loaded = try? JSONDecoder().decode(StyleProfile.self, from: data) {
            profile = loaded
        } else {
            profile = StyleProfile()
        }
    }
    
    /// Record a successful transcription (user accepted the result)
    func recordSuccess(raw: String, polished: String, appName: String) {
        profile.totalDictations += 1
        profile.totalCharsTranscribed += polished.count
        
        // Detect primary language from recent output
        let hasChineseChars = polished.unicodeScalars.contains(where: { $0.value >= 0x4E00 && $0.value <= 0x9FFF })
        let hasLatinChars = polished.unicodeScalars.contains(where: { $0.value >= 0x41 && $0.value <= 0x7A })
        if hasChineseChars && hasLatinChars {
            profile.primaryLanguage = "mixed"
        } else if hasChineseChars {
            profile.primaryLanguage = "zh"
        } else {
            profile.primaryLanguage = "en"
        }
        
        // Keep last 10 good examples (> 20 chars, not silence/error)
        if polished.count > 20 {
            let example = StyleExample(
                raw: String(raw.prefix(200)),
                polished: String(polished.prefix(200)),
                app: appName
            )
            profile.recentExamples.append(example)
            if profile.recentExamples.count > 10 {
                profile.recentExamples.removeFirst()
            }
        }
        
        profile.lastUpdated = ISO8601DateFormatter().string(from: Date())
        save()
    }
    
    /// Get a personalization snippet for the polisher prompt
    func polisherPersonalization() -> String? {
        guard profile.totalDictations >= 5 else { return nil }  // Need enough data
        
        var lines: [String] = []
        
        // Language preference
        switch profile.primaryLanguage {
        case "mixed":
            lines.append("This user frequently mixes Chinese and English. Preserve both languages naturally.")
        case "zh":
            lines.append("This user primarily speaks Chinese. Keep output in Chinese with English technical terms preserved.")
        case "en":
            lines.append("This user primarily speaks English.")
        default:
            break
        }
        
        // Show 2-3 recent examples for style reference
        let goodExamples = profile.recentExamples.suffix(3)
        if !goodExamples.isEmpty {
            lines.append("Recent examples of this user's accepted style:")
            for ex in goodExamples {
                lines.append("  Input: \"\(ex.raw.prefix(80))\"")
                lines.append("  Output: \"\(ex.polished.prefix(80))\"")
            }
        }
        
        if lines.isEmpty { return nil }
        return "USER PERSONALIZATION:\n" + lines.joined(separator: "\n")
    }
    
    /// Progress percentage (0-100) for UI display
    var progressPercent: Int {
        // 0-20 dictations = 0-50%, 20-100 = 50-80%, 100+ = 80-100%
        let count = profile.totalDictations
        if count < 20 { return min(count * 5 / 2, 50) }
        if count < 100 { return 50 + (count - 20) * 30 / 80 }
        return min(80 + (count - 100) / 10, 100)
    }
    
    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(profile) {
            try? data.write(to: profilePath)
        }
    }
}
