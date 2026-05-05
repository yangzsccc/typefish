import Foundation
import AppKit

/// Monitors user edits after paste to auto-learn dictionary corrections.
///
/// Inspired by Typeless's edit tracking (reverse-engineered 2026-03-19).
/// Key difference: Typeless sends edits to their server for phonetic analysis.
/// We do it locally with a lightweight Groq LLM call.
///
/// Flow:
/// 1. After successful paste, starts 15-second monitoring window
/// 2. Polls focused text field every 2 seconds via AX API
/// 3. If pasted text was modified, sends original + edited to LLM
/// 4. LLM identifies phonetic/speech-recognition corrections
/// 5. Auto-adds corrections to dictionary (replacements + hints)
class EditTracker {

    static let shared = EditTracker()

    private let trackingDuration: TimeInterval = 15
    private let debounceDelay: TimeInterval = 0.3  // 300ms after keypress before reading

    private var trackedText: String?
    private var trackingStartTime: Date?
    private var apiKey: String?
    private weak var appState: AppState?

    /// Debounce: wait for text to stabilize before analyzing
    private var lastChangeTime: Date?
    private var lastFieldContent: String?
    private let stabilizeDelay: TimeInterval = 3  // seconds of no changes before analyzing

    /// Prevent tracking during certain states
    private var isAnalyzing = false
    private var keypressLogCount = 0
    private var cannotReadLogCount = 0

    /// Debounce work item for keypress handling
    private var debounceWorkItem: DispatchWorkItem?

    /// Timeout work item for 15s tracking window
    private var timeoutWorkItem: DispatchWorkItem?

    /// Clipboard fallback for Electron apps
    private static var lastPastedText: String?
    private static var lastPasteTime: Date?

    private init() {}

    static func computeDiffForTesting(original: String, edited: String) -> [(removed: String, inserted: String)] {
        shared.computeDiff(original: original, edited: edited)
    }

    static func hasSignificantOverlapForTesting(_ original: String, _ edited: String) -> Bool {
        shared.hasSignificantOverlap(original, edited)
    }

    static func parseCorrectionsForTesting(_ text: String, sourceText: String, editedText: String) -> [(String, String)] {
        shared.parseCorrections(text, sourceText: sourceText, editedText: editedText)
    }

    // MARK: - Public API

    /// Start tracking after a successful paste.
    /// Call this from AppState after PasteService.paste() returns true.
    func startTracking(pastedText: String, apiKey: String, appState: AppState) {
        // Don't start if already tracking or analyzing
        guard !isAnalyzing else { return }

        // Check clipboard fallback: if AX failed last time, check clipboard for edits
        checkClipboardFallback(apiKey: apiKey, appState: appState)

        stopTracking()

        // Skip very short text (not worth tracking)
        guard pastedText.count >= 4 else { return }

        // Save tracking state
        self.trackedText = pastedText
        self.apiKey = apiKey
        self.appState = appState
        self.trackingStartTime = Date()

        // Save for clipboard fallback
        EditTracker.lastPastedText = pastedText
        EditTracker.lastPasteTime = Date()

        // Enable keyboard event tracking
        HotkeyManager.shared?.isTrackingEdits = true

        // Wire up keyboard callbacks
        HotkeyManager.shared?.onAnyKeyPress = { [weak self] in
            self?.handleKeyPress()
        }

        HotkeyManager.shared?.onEnterKey = { [weak self] in
            self?.handleEnterKey()
        }

        // Set up 15s timeout
        let timeoutItem = DispatchWorkItem { [weak self] in
            self?.handleTimeout()
        }
        self.timeoutWorkItem = timeoutItem
        DispatchQueue.main.asyncAfter(deadline: .now() + trackingDuration, execute: timeoutItem)

        Log.info("📝 EditTracker: started keyboard-driven tracking for \(pastedText.count) chars")
    }

    /// Check clipboard for edits (fallback for Electron apps where AX fails)
    private func checkClipboardFallback(apiKey: String, appState: AppState) {
        guard let lastPasted = EditTracker.lastPastedText,
              let lastTime = EditTracker.lastPasteTime,
              Date().timeIntervalSince(lastTime) < 60 else {  // Only check within 60s
            return
        }

        guard let clipboardContent = NSPasteboard.general.string(forType: .string),
              !clipboardContent.isEmpty,
              clipboardContent != lastPasted else {
            return
        }

        guard hasSignificantOverlap(lastPasted, clipboardContent) else {
            Log.info("📝 EditTracker: clipboard fallback ignored unrelated clipboard text")
            return
        }

        // Check if clipboard differs by small edit
        let diff = computeDiff(original: lastPasted, edited: clipboardContent)
        if !diff.isEmpty && !isLargeModification(original: lastPasted, edited: clipboardContent) {
            Log.info("📝 EditTracker: clipboard fallback detected \(diff.count) correction(s)")
            analyzeEdit(pastedText: lastPasted, editedFieldContent: clipboardContent, apiKey: apiKey, appState: appState)
        }
    }

    /// Stop tracking (called on timeout, new recording, or edit detected)
    func stopTracking() {
        // Cancel pending work items
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil

        // Clear state
        trackedText = nil
        trackingStartTime = nil
        apiKey = nil
        appState = nil
        lastChangeTime = nil
        lastFieldContent = nil

        // Log summary of suppressed messages
        if cannotReadLogCount > 1 {
            Log.info("📝 EditTracker: 'cannot read field content' occurred \(cannotReadLogCount) times total")
        }
        if keypressLogCount > 1 {
            Log.info("📝 EditTracker: \(keypressLogCount) keypresses detected total")
        }
        keypressLogCount = 0
        cannotReadLogCount = 0

        // Disable keyboard tracking
        HotkeyManager.shared?.isTrackingEdits = false
        HotkeyManager.shared?.onAnyKeyPress = nil
        HotkeyManager.shared?.onEnterKey = nil
    }

    // MARK: - Keyboard Event Handlers

    /// Called on every keypress while tracking is active
    private func handleKeyPress() {
        // Cancel any pending debounce
        debounceWorkItem?.cancel()

        // Reset the 15s timeout (each keypress extends the window)
        timeoutWorkItem?.cancel()
        let timeoutItem = DispatchWorkItem { [weak self] in
            self?.handleTimeout()
        }
        self.timeoutWorkItem = timeoutItem
        DispatchQueue.main.asyncAfter(deadline: .now() + trackingDuration, execute: timeoutItem)

        // Schedule debounced text reading
        let workItem = DispatchWorkItem { [weak self] in
            self?.readAndCheckForEdits()
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceDelay, execute: workItem)

        // Only log first keypress to reduce noise (hundreds of these in Discord)
        if keypressLogCount == 0 {
            Log.info("📝 EditTracker: keypress detected, waiting \(Int(debounceDelay * 1000))ms...")
        }
        keypressLogCount += 1
    }

    /// Called when Enter key is pressed — trigger immediate analysis
    private func handleEnterKey() {
        Log.info("📝 EditTracker: Enter key pressed, triggering immediate analysis (after \(keypressLogCount) keypresses)")
        debounceWorkItem?.cancel()
        readAndCheckForEdits(immediate: true)
    }

    /// Called when 15s timeout expires
    private func handleTimeout() {
        guard let tracked = trackedText else { return }

        // If there's a pending stable edit, analyze it
        if let lastContent = lastFieldContent, lastChangeTime != nil {
            Log.info("📝 EditTracker: timeout with pending edit, analyzing")
            triggerAnalysis(pastedText: tracked, editedField: lastContent)
        } else {
            Log.info("📝 EditTracker: timeout, no edit detected")
            stopTracking()
        }
    }

    /// Read current text and check for edits
    private func readAndCheckForEdits(immediate: Bool = false) {
        guard let tracked = trackedText else {
            stopTracking()
            return
        }

        // Try cursor-aware reading first
        var currentContent: String
        if let inputState = ContextReader.readInputState() {
            Log.info("📝 EditTracker: read input state: before=\(inputState.beforeCursor.count) chars, after=\(inputState.afterCursor.count) chars")
            currentContent = inputState.fullContent
        } else if let fullContent = ContextReader.readFullContent() {
            // Fallback to full content reading
            Log.info("📝 EditTracker: cursor reading failed, using full content")
            currentContent = fullContent
        } else {
            cannotReadLogCount += 1
            if cannotReadLogCount == 1 {
                Log.info("📝 EditTracker: cannot read field content (further occurrences suppressed)")
            }
            return
        }

        // Field cleared
        guard !currentContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Log.info("📝 EditTracker: field cleared, stopping")
            stopTracking()
            return
        }

        // Check for large modifications using character-level diff
        if isLargeModification(original: tracked, edited: currentContent) {
            Log.info("📝 EditTracker: large modification detected (orig=\(tracked.count) edit=\(currentContent.count)), stopping")
            stopTracking()
            return
        }

        // If pasted text still present verbatim, no edit yet
        if currentContent.contains(tracked) {
            lastChangeTime = nil
            lastFieldContent = nil
            return
        }

        // Text has changed!
        let now = Date()

        // If immediate analysis (Enter key), skip stability check
        if immediate {
            Log.info("📝 EditTracker: immediate analysis triggered")
            triggerAnalysis(pastedText: tracked, editedField: currentContent)
            return
        }

        // If content changed since last check, reset stability timer
        if lastFieldContent != currentContent {
            if lastFieldContent == nil {
                Log.info("📝 EditTracker: edit started, waiting for stability...")
            }
            lastChangeTime = now
            lastFieldContent = currentContent
            return
        }

        // Content same as last check — verify stability
        guard let changeTime = lastChangeTime else { return }

        if now.timeIntervalSince(changeTime) >= stabilizeDelay {
            Log.info("📝 EditTracker: edit stabilized after \(String(format: "%.1f", now.timeIntervalSince(changeTime)))s")
            triggerAnalysis(pastedText: tracked, editedField: currentContent)
        }
    }

    private func triggerAnalysis(pastedText: String, editedField: String) {
        let savedKey = apiKey ?? ""
        let savedAppState = appState

        stopTracking()

        analyzeEdit(
            pastedText: pastedText,
            editedFieldContent: editedField,
            apiKey: savedKey,
            appState: savedAppState
        )
    }

    // MARK: - Token-Level Diff

    /// Compute token-level differences between original and edited text.
    /// Returns array of (removed, inserted) string pairs.
    private func computeDiff(original: String, edited: String) -> [(removed: String, inserted: String)] {
        let originalTokens = tokenizeForDiff(original)
        let editedTokens = tokenizeForDiff(edited)

        guard originalTokens != editedTokens else { return [] }

        var start = 0
        while start < originalTokens.count,
              start < editedTokens.count,
              originalTokens[start].caseInsensitiveCompare(editedTokens[start]) == .orderedSame {
            start += 1
        }

        var originalEnd = originalTokens.count - 1
        var editedEnd = editedTokens.count - 1
        while originalEnd >= start,
              editedEnd >= start,
              originalTokens[originalEnd].caseInsensitiveCompare(editedTokens[editedEnd]) == .orderedSame {
            originalEnd -= 1
            editedEnd -= 1
        }

        let removedTokens = start <= originalEnd ? Array(originalTokens[start...originalEnd]) : []
        let insertedTokens = start <= editedEnd ? Array(editedTokens[start...editedEnd]) : []
        let removedText = renderDiffTokens(removedTokens)
        let insertedText = renderDiffTokens(insertedTokens)

        if !removedText.isEmpty || !insertedText.isEmpty {
            return [(removed: removedText, inserted: insertedText)]
        }

        return []
    }

    private func tokenizeForDiff(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""

        func flushCurrent() {
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }

        for char in text {
            if isCJK(char) {
                flushCurrent()
                tokens.append(String(char))
            } else if char.isLetter || char.isNumber || char == "'" {
                current.append(char)
            } else {
                flushCurrent()
            }
        }
        flushCurrent()

        return tokens
    }

    private func renderDiffTokens(_ tokens: [String]) -> String {
        var rendered = ""
        var previousWasCJK = false

        for token in tokens {
            let currentIsCJK = token.count == 1 && token.first.map(isCJK) == true
            if rendered.isEmpty {
                rendered = token
            } else if previousWasCJK || currentIsCJK {
                rendered += token
            } else {
                rendered += " " + token
            }
            previousWasCJK = currentIsCJK
        }

        return rendered
    }

    private func isCJK(_ char: Character) -> Bool {
        char.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value))
        }
    }

    private func hasSignificantOverlap(_ original: String, _ edited: String) -> Bool {
        let originalTokens = Set(tokenizeForDiff(original).map { $0.lowercased() })
        let editedTokens = Set(tokenizeForDiff(edited).map { $0.lowercased() })
        guard !originalTokens.isEmpty, !editedTokens.isEmpty else { return false }

        let intersection = originalTokens.intersection(editedTokens).count
        let union = originalTokens.union(editedTokens).count
        return Double(intersection) / Double(union) >= 0.45
    }

    /// Check if modification is too large (>50% removed OR changed >2x)
    private func isLargeModification(original: String, edited: String) -> Bool {
        let origCount = original.count
        let editCount = edited.count

        // More than 50% content removed
        if editCount < origCount / 2 {
            return true
        }

        // Changed more than 2x
        if editCount > origCount * 2 || origCount > editCount * 2 {
            return true
        }

        return false
    }

    // MARK: - LLM Analysis

    private func analyzeEdit(
        pastedText: String,
        editedFieldContent: String,
        apiKey: String,
        appState: AppState?
    ) {
        guard !apiKey.isEmpty else {
            Log.info("📝 EditTracker: no API key for analysis")
            return
        }

        isAnalyzing = true

        guard let url = URL(string: "https://api.groq.com/openai/v1/chat/completions") else {
            isAnalyzing = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let systemPrompt = """
        You compare two texts to find speech recognition (STT) errors that the user manually corrected.

        TEXT A = the original STT output (what the speech-to-text system produced)
        TEXT B = the corrected version (what the user changed it to)

        Find words in TEXT A that the user replaced with different words in TEXT B because the STT got them wrong.
        Only report replacements where the wrong word SOUNDS SIMILAR to the correct word (phonetic error):
        - Chinese homophones (同音字/近音字)
        - English words that sound similar
        - Mixed: English word misheard as Chinese or vice versa

        Do NOT report: punctuation changes, added/deleted text, formatting, grammar edits.

        Output format — the STT wrong word first, then arrow, then the user's correction:
        [wrong word from TEXT A] → [correct word from TEXT B]

        One correction per line. If none found, output exactly: NONE
        """

        // Cap field content to avoid huge payloads
        let cappedField = String(editedFieldContent.prefix(2000))

        // Compute diff for more precise prompt
        let diffs = computeDiff(original: pastedText, edited: cappedField)

        let userMessage: String
        if diffs.count == 1, let diff = diffs.first {
            // Small, focused diff — send specific change
            let removed = diff.removed.trimmingCharacters(in: .whitespacesAndNewlines)
            let inserted = diff.inserted.trimmingCharacters(in: .whitespacesAndNewlines)

            if !removed.isEmpty && !inserted.isEmpty && removed.count < 50 && inserted.count < 50 {
                userMessage = """
                Changed: \(removed) → \(inserted)

                (Original full text: \(pastedText))
                """
                Log.info("📝 EditTracker: using focused diff prompt: [\(removed)] → [\(inserted)]")
            } else {
                // Fallback to full comparison
                userMessage = """
                TEXT A (original STT output):
                \(pastedText)

                TEXT B (after user's manual correction):
                \(cappedField)
                """
            }
        } else {
            // Multiple changes or complex diff — use full comparison
            userMessage = """
            TEXT A (original STT output):
            \(pastedText)

            TEXT B (after user's manual correction):
            \(cappedField)
            """
        }

        let payload: [String: Any] = [
            "model": "llama-3.3-70b-versatile",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage]
            ],
            "temperature": 0.0,
            "max_tokens": 200
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            isAnalyzing = false
            return
        }
        request.httpBody = jsonData

        Log.info("📝 EditTracker: analyzing — original=[\(pastedText)] field=[\(String(cappedField.prefix(100)))]")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            defer { self?.isAnalyzing = false }

            if let error = error {
                Log.info("📝 EditTracker: LLM error: \(error.localizedDescription)")
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                Log.info("📝 EditTracker: LLM bad response")
                return
            }

            let result = content.trimmingCharacters(in: .whitespacesAndNewlines)

            // Treat various "no corrections" responses as NONE
            let lowerResult = result.lowercased()
            if result == "NONE" || result.isEmpty
                || lowerResult.contains("no phonetic")
                || lowerResult.contains("no speech")
                || lowerResult.contains("no correction")
                || lowerResult.contains("no error")
                || lowerResult.contains("no stt")
                || lowerResult.contains("none found")
                || lowerResult.contains("no replacement")
                || (lowerResult.hasPrefix("(") && lowerResult.hasSuffix(")") && lowerResult.contains("found")) {
                Log.info("📝 EditTracker: no speech recognition corrections found (response: \(result.prefix(60)))")
                return
            }

            let corrections = self?.parseCorrections(result, sourceText: pastedText, editedText: cappedField) ?? []

            if corrections.isEmpty {
                Log.info("📝 EditTracker: no valid corrections parsed from: \(result)")
                return
            }

            // Apply corrections to dictionary
            DispatchQueue.main.async { [weak self] in
                guard let appState = appState else { return }

                for (wrong, right) in corrections {
                    // Add as replacement only (doesn't use Whisper prompt space)
                    appState.dictionary.addReplacement(wrong: wrong, right: right, source: .autoLearned)
                    Log.info("📝 Auto-learned: \(wrong) → \(right)")
                }

                // Show overlay notification with Undo for the first correction
                if let first = corrections.first {
                    let allCorrections = corrections
                    appState.overlay.showAutoLearn(
                        wrong: first.0,
                        right: first.1,
                        onUndo: {
                            // Remove all corrections that were just added
                            for (wrong, _) in allCorrections {
                                appState.dictionary.replacements.removeValue(forKey: wrong)
                                Log.info("📝 Undo auto-learn: removed \(wrong)")
                            }
                            appState.dictionary.save()
                        }
                    )
                }

                // Log for offline analysis
                self?.logAutoCorrection(
                    corrections: corrections,
                    original: pastedText,
                    editedField: cappedField
                )
            }
        }.resume()
    }

    // MARK: - Parsing

    /// Parse "wrong → right" lines from LLM output
    private func parseCorrections(_ text: String, sourceText: String, editedText: String) -> [(String, String)] {
        var corrections: [(String, String)] = []
        var seen: Set<String> = []

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // Try arrow formats: →, ->, =>
            let separators = [" → ", "→", " -> ", "->", " => ", "=>"]
            for sep in separators {
                if let range = trimmed.range(of: sep) {
                    let wrong = String(trimmed[..<range.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`-•"))
                    let right = String(trimmed[range.upperBound...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`-•"))

                    // Context-aware validation
                    if isValidCorrection(wrong: wrong, right: right, sourceText: sourceText, editedText: editedText) {
                        let key = wrong.lowercased()
                        if !seen.contains(key) {
                            corrections.append((wrong, right))
                            seen.insert(key)
                        }
                    }
                    break
                }
            }
        }

        return corrections
    }

    // MARK: - Validation Hard-Gates

    /// Context-aware validation: candidate must pass ALL gates to be accepted.
    private func isValidCorrection(wrong: String, right: String, sourceText: String, editedText: String) -> Bool {
        // Both must be non-empty and different
        guard !wrong.isEmpty, !right.isEmpty, wrong != right else { return false }

        // --- Gate 0: Parsing artifact rejection ---
        guard !wrong.contains("→"), !right.contains("→"),
              !wrong.contains("->"), !right.contains("->") else {
            Log.info("📝 REJECT (arrow artifact): \(wrong) / \(right)")
            return false
        }

        // --- Gate 1: Length bounds ---
        guard wrong.count >= 2, right.count >= 2 else {
            Log.info("📝 REJECT (too short): \(wrong) / \(right)")
            return false
        }
        guard wrong.count <= 20, right.count <= 20 else {
            Log.info("📝 REJECT (too long): \(wrong.prefix(20))... / \(right.prefix(20))...")
            return false
        }

        // --- Gate 2: Length ratio <= 2.0, absolute diff <= 4 ---
        let lenRatio = Double(max(wrong.count, right.count)) / Double(max(min(wrong.count, right.count), 1))
        guard lenRatio <= 2.0 else {
            Log.info("📝 REJECT (length ratio \(String(format: "%.1f", lenRatio))x): \(wrong) / \(right)")
            return false
        }
        let absDiff = abs(wrong.count - right.count)
        guard absDiff <= 4 else {
            Log.info("📝 REJECT (abs length diff \(absDiff)): \(wrong) / \(right)")
            return false
        }

        // --- Gate 3: Source-of-truth — wrong must appear in STT, right in edited ---
        guard sourceText.contains(wrong) else {
            Log.info("📝 REJECT (wrong not in source STT): [\(wrong)] not found in [\(sourceText.prefix(80))]")
            return false
        }
        guard editedText.contains(right) else {
            Log.info("📝 REJECT (right not in edited text): [\(right)] not found in [\(editedText.prefix(80))]")
            return false
        }

        // --- Gate 4: Blocklist — LLM noise + functional words + common junk ---
        let lowerWrong = wrong.lowercased()
        let lowerRight = right.lowercased()

        let noiseWords: Set<String> = [
            "wrong", "right", "none", "original", "corrected", "text", "word",
            "error", "found", "phonetic", "correction", "replacement", "unchanged",
            "speech", "transcription", "stt"
        ]
        guard !noiseWords.contains(lowerWrong), !noiseWords.contains(lowerRight) else {
            Log.info("📝 REJECT (noise word): \(wrong) / \(right)")
            return false
        }

        guard !lowerWrong.contains("phonetic"), !lowerRight.contains("phonetic"),
              !lowerWrong.contains("error found"), !lowerRight.contains("error found"),
              !lowerWrong.contains("no correction"), !lowerRight.contains("no correction") else {
            Log.info("📝 REJECT (LLM commentary): \(wrong) / \(right)")
            return false
        }

        // Expanded Chinese functional / common word blocklist
        let blockedTokens: Set<String> = [
            // Single-char functional words
            "的", "了", "是", "在", "有", "这", "那", "就", "也", "都",
            "不", "会", "到", "和", "与", "而", "但", "或", "把", "被",
            "让", "给", "从", "对", "向", "过", "着", "吗", "呢", "吧",
            "啊", "哦", "嗯", "哈", "呀", "么", "很", "可", "能", "要",
            // Common English functional words
            "the", "a", "an", "is", "am", "are", "was", "were", "be",
            "to", "of", "in", "on", "at", "for", "and", "or", "but",
            "it", "he", "she", "we", "they", "my", "your", "his", "her",
            "this", "that", "with", "from", "not", "so", "if", "do",
            "i", "me", "you", "us", "them"
        ]
        if blockedTokens.contains(wrong) || blockedTokens.contains(right)
            || blockedTokens.contains(lowerWrong) || blockedTokens.contains(lowerRight) {
            Log.info("📝 REJECT (blocked functional token): \(wrong) / \(right)")
            return false
        }

        // --- Gate 5: Phonetic similarity ---
        let similarity = phoneticSimilarity(wrong: wrong, right: right)
        let threshold: Double = 0.4  // Conservative — must share ≥40% phonetic overlap
        guard similarity >= threshold else {
            Log.info("📝 REJECT (phonetic similarity \(String(format: "%.2f", similarity)) < \(threshold)): \(wrong) / \(right)")
            return false
        }

        Log.info("📝 ACCEPT (similarity=\(String(format: "%.2f", similarity))): \(wrong) → \(right)")
        return true
    }

    // MARK: - Phonetic Similarity

    /// Compute phonetic similarity between two strings.
    /// Chinese: convert to pinyin via CFStringTransform, then compare.
    /// English: normalize to lowercase alphanumeric, then compare.
    /// Returns 0.0 (completely different) to 1.0 (identical).
    private func phoneticSimilarity(wrong: String, right: String) -> Double {
        let wrongPinyin = toPhoneticKey(wrong)
        let rightPinyin = toPhoneticKey(right)

        guard !wrongPinyin.isEmpty, !rightPinyin.isEmpty else { return 0.0 }

        let distance = levenshteinDistance(wrongPinyin, rightPinyin)
        let maxLen = max(wrongPinyin.count, rightPinyin.count)
        return 1.0 - Double(distance) / Double(maxLen)
    }

    /// Convert a string to a phonetic key for comparison.
    /// Chinese characters → pinyin (via Foundation CFStringTransform).
    /// English/other → lowercase alphanumeric only.
    private func toPhoneticKey(_ text: String) -> String {
        let mutable = NSMutableString(string: text)

        // Convert Chinese to Latin (pinyin) — Foundation built-in
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        // Strip diacritics (tone marks)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)

        // Normalize: lowercase, keep only alphanumeric
        let normalized = (mutable as String)
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map { String($0) }
            .joined()

        return normalized
    }

    /// Standard Levenshtein edit distance.
    private func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1)
        let b = Array(s2)
        let m = a.count
        let n = b.count

        if m == 0 { return n }
        if n == 0 { return m }

        var prev = Array(0...n)
        var curr = Array(repeating: 0, count: n + 1)

        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,       // deletion
                    curr[j - 1] + 1,   // insertion
                    prev[j - 1] + cost  // substitution
                )
            }
            prev = curr
        }

        return prev[n]
    }

    // MARK: - Logging

    private func logAutoCorrection(
        corrections: [(String, String)],
        original: String,
        editedField: String
    ) {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/typefish/logs")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let logFile = logsDir.appendingPathComponent("auto-corrections.jsonl")

        let entry: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "original_pasted": original,
            "edited_field": editedField,
            "corrections": corrections.map { ["wrong": $0.0, "right": $0.1] }
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
              var jsonString = String(data: jsonData, encoding: .utf8) else { return }
        jsonString += "\n"

        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            handle.write(jsonString.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? jsonString.data(using: .utf8)?.write(to: logFile)
        }

        Log.info("📝 EditTracker: logged \(corrections.count) correction(s) to auto-corrections.jsonl")
    }
}
