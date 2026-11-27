import Foundation

enum ReplacementSource: String, Codable, CaseIterable {
    case manual
    case autoLearned
    case imported
}

struct ReplacementMetadata: Codable, Equatable {
    var source: ReplacementSource
    var createdAt: String
    var updatedAt: String
}

struct LearnedSpellingPreference: Codable, Equatable, Identifiable {
    var id: UUID
    var phrase: String
    var createdAt: String
    var updatedAt: String? = nil
}

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
    /// Provenance for replacement entries, keyed by the "wrong" text.
    var replacementMetadata: [String: ReplacementMetadata] = [:]
    /// Spelling targets learned from user corrections, prioritized in prompts.
    var learnedSpellingPreferences: [LearnedSpellingPreference] = []
    private var storageURL: URL

    // Legacy support: if old format has "vocabulary" but no "hints", migrate
    private enum CodingKeys: String, CodingKey {
        case hints, replacements, vocabulary, replacementMetadata, learnedSpellingPreferences
        // Ignore _comment fields
    }

    init(
        hints: [String] = [],
        replacements: [String: String] = [:],
        vocabulary: [String] = [],
        replacementMetadata: [String: ReplacementMetadata] = [:],
        learnedSpellingPreferences: [LearnedSpellingPreference] = [],
        storageURL: URL = fileURL
    ) {
        self.hints = hints
        self.replacements = replacements
        self.vocabulary = vocabulary
        self.replacementMetadata = replacementMetadata
        self.learnedSpellingPreferences = learnedSpellingPreferences
        self.storageURL = storageURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.hints = try container.decodeIfPresent([String].self, forKey: .hints) ?? []
        self.replacements = try container.decodeIfPresent([String: String].self, forKey: .replacements) ?? [:]
        self.vocabulary = try container.decodeIfPresent([String].self, forKey: .vocabulary) ?? []
        self.replacementMetadata = try container.decodeIfPresent([String: ReplacementMetadata].self, forKey: .replacementMetadata) ?? [:]
        self.learnedSpellingPreferences = try container.decodeIfPresent([LearnedSpellingPreference].self, forKey: .learnedSpellingPreferences) ?? []
        self.storageURL = Self.fileURL
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hints, forKey: .hints)
        try container.encode(replacements, forKey: .replacements)
        try container.encode(vocabulary, forKey: .vocabulary)
        if !replacementMetadata.isEmpty {
            try container.encode(replacementMetadata, forKey: .replacementMetadata)
        }
        if !learnedSpellingPreferences.isEmpty {
            try container.encode(learnedSpellingPreferences, forKey: .learnedSpellingPreferences)
        }
    }

    // MARK: - File Management

    static var fileURL: URL {
        if let override = ProcessInfo.processInfo.environment["TYPEFISH_DICTIONARY_PATH"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            return url
        }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/typefish")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dictionary.json")
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    /// Load dictionary from disk. Creates with defaults if file doesn't exist.
    static func load(from url: URL = fileURL) -> CustomDictionary {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode(CustomDictionary.self, from: data) else {
            var dict = loadDefaults()
            dict.storageURL = url
            dict.save()
            Log.info("📖 Created dictionary: \(dict.hints.count) hints, \(dict.replacements.count) replacements, \(dict.vocabulary.count) vocab")
            return dict
        }
        Log.info("📖 Dictionary: \(dict.hints.count) hints, \(dict.replacements.count) replacements, \(dict.vocabulary.count) vocab")
        var sanitized = dict
        sanitized.storageURL = url
        let removedGarbage = sanitized.sanitizeReplacements()
        let migratedLegacyLearnedRules = sanitized.migrateLegacyAutoLearnedReplacements()
        if removedGarbage || migratedLegacyLearnedRules {
            if !sanitized.save(to: url) { Log.info("Dictionary migration will be retried on reload") }
        }
        return sanitized
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

    /// Remove garbage auto-learned replacements.
    /// Aligned with EditTracker P0 hard-gates: length ratio ≤2.0, abs diff ≤4,
    /// blocked tokens, LLM commentary, garbled text.
    /// Returns true if any were removed.
    mutating func sanitizeReplacements() -> Bool {
        var removed: [String] = []

        let blockedTokens: Set<String> = [
            "的", "了", "是", "在", "有", "这", "那", "就", "也", "都",
            "不", "会", "到", "和", "与", "而", "但", "或", "把", "被",
            "让", "给", "从", "对", "向", "过", "着", "吗", "呢", "吧",
            "啊", "哦", "嗯", "哈", "呀", "么", "很", "可", "能", "要",
            "the", "a", "an", "is", "am", "are", "was", "were", "be",
            "to", "of", "in", "on", "at", "for", "and", "or", "but",
            "it", "he", "she", "we", "they", "my", "your", "his", "her",
            "this", "that", "with", "from", "not", "so", "if", "do",
            "i", "me", "you", "us", "them"
        ]

        for (wrong, right) in replacements where metadata(for: wrong).source == .autoLearned {
            let lowerRight = right.lowercased()
            let lowerWrong = wrong.lowercased()

            // Remove if value contains LLM commentary
            if lowerRight.contains("phonetic") || lowerRight.contains("error found")
                || lowerRight.contains("no correction") || lowerRight.contains("unchanged") {
                removed.append(wrong)
                continue
            }

            // Remove if key contains LLM commentary
            if lowerWrong.contains("phonetic") || lowerWrong.contains("error found") {
                removed.append(wrong)
                continue
            }

            // Remove blocked functional tokens
            if blockedTokens.contains(wrong) || blockedTokens.contains(right)
                || blockedTokens.contains(lowerWrong) || blockedTokens.contains(lowerRight) {
                removed.append(wrong)
                continue
            }

            // Remove if length ratio > 2.0 or absolute diff > 4
            let lenRatio = Double(max(wrong.count, right.count)) / Double(max(min(wrong.count, right.count), 1))
            if lenRatio > 2.0 || abs(wrong.count - right.count) > 4 {
                removed.append(wrong)
                continue
            }

            // Remove reversed/garbled text
            let hasWeirdMix = wrong.unicodeScalars.contains(where: { $0.value > 0x4E00 })
                && wrong.unicodeScalars.contains(where: { $0.value < 128 && CharacterSet.letters.contains($0) })
                && wrong.count > 10
            if hasWeirdMix && !right.contains(wrong.prefix(3)) {
                removed.append(wrong)
                continue
            }
        }

        if !removed.isEmpty {
            for key in removed {
                let val = replacements.removeValue(forKey: key) ?? "?"
                replacementMetadata.removeValue(forKey: key)
                Log.info("   🗑 \(key) → \(val)")
            }
            Log.info("🧹 Sanitized \(removed.count) garbage dictionary entries")
        }

        return !removed.isEmpty
    }

    /// Convert explicitly auto-learned global replacements into spelling guidance.
    /// Legacy rules without provenance remain imported and retain their behavior.
    @discardableResult
    mutating func migrateLegacyAutoLearnedReplacements() -> Bool {
        let learnedRules = replacements.filter { metadata(for: $0.key).source == .autoLearned }
        guard !learnedRules.isEmpty else { return false }

        for (wrong, right) in learnedRules {
            let isAlreadyHinted = uniqueStrings(learnedSpellingPreferences.map(\.phrase) + hints)
                .contains { $0.compare(right, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
            if !isAlreadyHinted {
                learnedSpellingPreferences.append(
                    LearnedSpellingPreference(id: UUID(), phrase: right, createdAt: Self.timestamp())
                )
            }
            replacements.removeValue(forKey: wrong)
            replacementMetadata.removeValue(forKey: wrong)
        }

        return true
    }

    /// Save to disk (pretty-printed for easy editing)
    @discardableResult
    mutating func save(to url: URL? = nil) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return false }
        let destination = url ?? storageURL
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
            storageURL = destination
            return true
        } catch {
            Log.info("⚠️ Failed to save dictionary: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Whisper Hints (spelling guide format)

    /// Build a Whisper prompt using "spelling guide" format.
    /// OpenAI recommends this over plain word lists.
    /// Groq limit: 896 characters.
    func whisperPrompt() -> String? {
        let promptHints = prioritizedSpellingHints()
        guard !promptHints.isEmpty else { return nil }

        // Spelling guide format — Whisper mimics the style of the prompt
        let prefix = "Spelling guide: "
        let maxChars = 896 - prefix.count

        var words: [String] = []
        var charCount = 0

        for hint in promptHints {
            let addition = words.isEmpty ? hint : ", \(hint)"
            if charCount + addition.count > maxChars { continue }
            words.append(hint)
            charCount += addition.count
        }

        guard !words.isEmpty else { return nil }

        var prompt = prefix + words.joined(separator: ", ")

        // Safety guard: hard-cap at 896 chars (Groq limit)
        // This catches edge cases where character counting differs from API
        if prompt.count > 896 {
            Log.info("⚠️ Whisper prompt over 896 (\(prompt.count)), truncating")
            prompt = String(prompt.prefix(896))
        }

        if words.count < promptHints.count {
            Log.info("📖 Whisper hints: \(words.count)/\(promptHints.count) (\(prompt.count) chars)")
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
            if shouldUseWordBoundaries(for: wrong) {
                let pattern = "\\b\(NSRegularExpression.escapedPattern(for: wrong))\\b"
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    let range = NSRange(result.startIndex..., in: result)
                    result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: right)
                }
            } else {
                result = result.replacingOccurrences(of: wrong, with: right)
            }
        }

        if result != text {
            Log.info("📖 Applied replacements")
        }
        return result
    }

    private func shouldUseWordBoundaries(for text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let scalars = text.unicodeScalars
        let hasCJK = scalars.contains { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value))
        }
        guard !hasCJK else { return false }
        return scalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    // MARK: - LLM Polisher Reference

    /// Build a reference list for the LLM polisher.
    /// Includes all hints + vocabulary + replacement targets.
    /// The LLM can use these to fix spelling that Whisper and replacements missed.
    func polisherReference() -> String? {
        let learned = learnedSpellingPreferences.reversed().map(\.phrase)
        let remaining = (hints + vocabulary + Array(replacements.values)).sorted()
        let words = uniqueStrings(learned + remaining)
        guard !words.isEmpty else { return nil }

        return "Known terms and correct spellings: " + words.joined(separator: ", ")
    }

    private func prioritizedSpellingHints() -> [String] {
        uniqueStrings(learnedSpellingPreferences.reversed().map(\.phrase) + hints)
    }

    private func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let key = value.trimmingCharacters(in: .whitespacesAndNewlines).folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - Add entries

    /// Add a hint word (sent to Whisper)
    mutating func addHint(_ word: String, persist: Bool = true) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !hints.contains(trimmed) else { return }
        hints.append(trimmed)
        if persist { save() }
        Log.info("📖 Added hint: \(trimmed)")
    }

    @discardableResult
    mutating func addLearnedSpellingPreference(
        _ phrase: String,
        persist: Bool = true
    ) -> LearnedSpellingPreference? {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let alreadyPresent = learnedSpellingPreferences.contains {
            $0.phrase.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) == key
        }
        guard !alreadyPresent else { return nil }

        let preference = LearnedSpellingPreference(id: UUID(), phrase: trimmed, createdAt: Self.timestamp())
        learnedSpellingPreferences.append(preference)
        if persist, !save() {
            learnedSpellingPreferences.removeAll { $0.id == preference.id }
            return nil
        }
        Log.info("📖 Added learned spelling preference: \(trimmed)")
        return preference
    }

    /// Remove only the exact learned record returned by `addLearnedSpellingPreference`.
    /// Missing records are already undone. Changed records are preserved.
    @discardableResult
    mutating func undoLearnedSpellingPreference(
        _ preference: LearnedSpellingPreference,
        persist: Bool = true
    ) -> Bool {
        guard let index = learnedSpellingPreferences.firstIndex(where: { $0.id == preference.id }) else {
            return true
        }
        guard learnedSpellingPreferences[index] == preference else { return false }
        learnedSpellingPreferences.remove(at: index)
        if persist, !save() {
            learnedSpellingPreferences.insert(preference, at: index)
            return false
        }
        Log.info("📖 Undid learned spelling preference: \(preference.phrase)")
        return true
    }

    @discardableResult
    mutating func updateLearnedSpellingPreference(
        _ preference: LearnedSpellingPreference,
        phrase: String,
        persist: Bool = true
    ) -> LearnedSpellingPreference? {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = learnedSpellingPreferences.firstIndex(where: { $0.id == preference.id }),
              learnedSpellingPreferences[index] == preference else {
            return nil
        }

        let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let duplicatesAnotherPreference = learnedSpellingPreferences.enumerated().contains { candidateIndex, candidate in
            candidateIndex != index
                && candidate.phrase.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) == key
        }
        guard !duplicatesAnotherPreference else { return nil }

        learnedSpellingPreferences[index].phrase = trimmed
        learnedSpellingPreferences[index].updatedAt = Self.timestamp()
        let updated = learnedSpellingPreferences[index]
        if persist, !save() {
            learnedSpellingPreferences[index] = preference
            return nil
        }
        Log.info("📖 Updated learned spelling preference: \(preference.phrase) → \(trimmed)")
        return updated
    }

    mutating func updateHint(oldValue: String, newValue: String, persist: Bool = true) {
        let old = oldValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !old.isEmpty, !new.isEmpty else { return }
        if let index = hints.firstIndex(of: old) {
            hints[index] = new
        } else if !hints.contains(new) {
            hints.append(new)
        }
        hints = Array(NSOrderedSet(array: hints).compactMap { $0 as? String })
        if persist { save() }
        Log.info("📖 Updated hint: \(old) → \(new)")
    }

    mutating func removeHint(_ word: String, persist: Bool = true) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        hints.removeAll { $0 == trimmed }
        if persist { save() }
        Log.info("📖 Removed hint: \(trimmed)")
    }

    func metadata(for wrong: String) -> ReplacementMetadata {
        replacementMetadata[wrong] ?? ReplacementMetadata(source: .imported, createdAt: "", updatedAt: "")
    }

    /// Add a replacement (wrong → right)
    mutating func addReplacement(
        wrong: String,
        right: String,
        source: ReplacementSource = .manual,
        persist: Bool = true
    ) {
        let w = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !r.isEmpty else { return }
        let now = CustomDictionary.timestamp()
        let existing = replacementMetadata[w]
        replacements[w] = r
        replacementMetadata[w] = ReplacementMetadata(
            source: source,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        if persist { save() }
        Log.info("📖 Added replacement: \(w) → \(r)")
    }

    mutating func updateReplacement(
        oldWrong: String,
        wrong: String,
        right: String,
        source: ReplacementSource? = nil,
        persist: Bool = true
    ) {
        let old = oldWrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let w = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !old.isEmpty, !w.isEmpty, !r.isEmpty else { return }

        let existing = replacementMetadata[old] ?? replacementMetadata[w]
        replacements.removeValue(forKey: old)
        replacementMetadata.removeValue(forKey: old)

        replacements[w] = r
        let now = CustomDictionary.timestamp()
        replacementMetadata[w] = ReplacementMetadata(
            source: source ?? existing?.source ?? .manual,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        if persist { save() }
        Log.info("📖 Updated replacement: \(w) → \(r)")
    }

    mutating func removeReplacement(_ wrong: String, persist: Bool = true) {
        let key = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        replacements.removeValue(forKey: key)
        replacementMetadata.removeValue(forKey: key)
        if persist { save() }
        Log.info("📖 Removed replacement: \(key)")
    }

    /// Add a vocabulary word (LLM reference)
    mutating func addVocabulary(_ word: String, persist: Bool = true) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !vocabulary.contains(trimmed) else { return }
        vocabulary.append(trimmed)
        if persist { save() }
        Log.info("📖 Added vocab: \(trimmed)")
    }

    mutating func updateVocabulary(oldValue: String, newValue: String, persist: Bool = true) {
        let old = oldValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !old.isEmpty, !new.isEmpty else { return }
        if let index = vocabulary.firstIndex(of: old) {
            vocabulary[index] = new
        } else if !vocabulary.contains(new) {
            vocabulary.append(new)
        }
        vocabulary = Array(NSOrderedSet(array: vocabulary).compactMap { $0 as? String })
        if persist { save() }
        Log.info("📖 Updated vocab: \(old) → \(new)")
    }

    mutating func removeVocabulary(_ word: String, persist: Bool = true) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        vocabulary.removeAll { $0 == trimmed }
        if persist { save() }
        Log.info("📖 Removed vocab: \(trimmed)")
    }
}
