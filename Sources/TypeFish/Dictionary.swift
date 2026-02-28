import Foundation

/// Custom dictionary with three-layer design:
/// 1. hints: Words Whisper struggles with → sent as "spelling guide" prompt (max 896 chars)
/// 2. replacements: Post-transcription corrections → 100% reliable find-replace
/// 3. vocabulary: Reference words for LLM polisher (not sent to Whisper)
struct CustomDictionary: Codable {
    /// Words Whisper is likely to get wrong — sent as spelling guide prompt
    var hints: [String] = []
    /// Post-transcription corrections: wrong → right
    var replacements: [String: String] = [:]
    /// Reference vocabulary for LLM polisher (NOT sent to Whisper)
    var vocabulary: [String] = []
    
    // Legacy support: if old format has "vocabulary" but no "hints", migrate
    private enum CodingKeys: String, CodingKey {
        case hints, replacements, vocabulary
        // Ignore _comment fields
    }
    
    // MARK: - File Management
    
    static let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/typefish")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dictionary.json")
    }()
    
    /// Load dictionary from disk. Creates with defaults if file doesn't exist.
    static func load() -> CustomDictionary {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode(CustomDictionary.self, from: data) else {
            var dict = loadDefaults()
            dict.save()
            Log.info("📖 Created dictionary: \(dict.hints.count) hints, \(dict.replacements.count) replacements, \(dict.vocabulary.count) vocab")
            return dict
        }
        Log.info("📖 Dictionary: \(dict.hints.count) hints, \(dict.replacements.count) replacements, \(dict.vocabulary.count) vocab")
        return dict
    }
    
    /// Load defaults from bundled file
    private static func loadDefaults() -> CustomDictionary {
        let paths = [
            Bundle.main.bundlePath + "/Contents/Resources/default-dictionary.json",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("typefish/default-dictionary.json").path
        ]
        
        for path in paths {
            if let data = FileManager.default.contents(atPath: path),
               let dict = try? JSONDecoder().decode(CustomDictionary.self, from: data) {
                Log.info("📖 Loaded defaults from \(path)")
                return dict
            }
        }
        
        Log.info("📖 No defaults found, starting empty")
        return CustomDictionary()
    }
    
    /// Save to disk (pretty-printed for easy editing)
    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: CustomDictionary.fileURL)
    }
    
    // MARK: - Whisper Hints (spelling guide format)
    
    /// Build a Whisper prompt using "spelling guide" format.
    /// OpenAI recommends this over plain word lists.
    /// Groq limit: 896 characters.
    func whisperPrompt() -> String? {
        guard !hints.isEmpty else { return nil }
        
        // Spelling guide format — Whisper mimics the style of the prompt
        let prefix = "Spelling guide: "
        let maxChars = 896 - prefix.count
        
        var words: [String] = []
        var charCount = 0
        
        for hint in hints {
            let addition = words.isEmpty ? hint : ", \(hint)"
            if charCount + addition.count > maxChars { break }
            words.append(hint)
            charCount += addition.count
        }
        
        guard !words.isEmpty else { return nil }
        
        let prompt = prefix + words.joined(separator: ", ")
        
        if words.count < hints.count {
            Log.info("📖 Whisper hints: \(words.count)/\(hints.count) (\(prompt.count) chars)")
        }
        
        return prompt
    }
    
    // MARK: - Replacements (post-transcription)
    
    /// Apply all replacements to transcribed text.
    /// Longer keys first to avoid partial matches.
    func applyReplacements(_ text: String) -> String {
        guard !replacements.isEmpty else { return text }
        
        var result = text
        let sorted = replacements.sorted { $0.key.count > $1.key.count }
        for (wrong, right) in sorted {
            result = result.replacingOccurrences(of: wrong, with: right)
        }
        
        if result != text {
            Log.info("📖 Applied replacements")
        }
        return result
    }
    
    // MARK: - LLM Polisher Reference
    
    /// Build a reference list for the LLM polisher.
    /// Includes all hints + vocabulary + replacement targets.
    /// The LLM can use these to fix spelling that Whisper and replacements missed.
    func polisherReference() -> String? {
        // Collect all "correct" words from all sources
        var allWords = Set<String>()
        allWords.formUnion(hints)
        allWords.formUnion(vocabulary)
        allWords.formUnion(replacements.values)  // The "right" side of replacements
        
        let sorted = allWords.sorted()
        guard !sorted.isEmpty else { return nil }
        
        return "Known terms and correct spellings: " + sorted.joined(separator: ", ")
    }
    
    // MARK: - Add entries
    
    /// Add a hint word (sent to Whisper)
    mutating func addHint(_ word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !hints.contains(trimmed) else { return }
        hints.append(trimmed)
        save()
        Log.info("📖 Added hint: \(trimmed)")
    }
    
    /// Add a replacement (wrong → right)
    mutating func addReplacement(wrong: String, right: String) {
        let w = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !r.isEmpty else { return }
        replacements[w] = r
        save()
        Log.info("📖 Added replacement: \(w) → \(r)")
    }
    
    /// Add a vocabulary word (LLM reference)
    mutating func addVocabulary(_ word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !vocabulary.contains(trimmed) else { return }
        vocabulary.append(trimmed)
        save()
        Log.info("📖 Added vocab: \(trimmed)")
    }
}
