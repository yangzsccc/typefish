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
    
    /// Debounce work item for keypress handling
    private var debounceWorkItem: DispatchWorkItem?
    
    /// Timeout work item for 15s tracking window
    private var timeoutWorkItem: DispatchWorkItem?
    
    /// Clipboard fallback for Electron apps
    private static var lastPastedText: String?
    private static var lastPasteTime: Date?
    
    private init() {}
    
    // MARK: - Public API
    
    /// Start tracking after a successful paste.
    /// Call this from AppState after PasteService.paste() returns true.
    func startTracking(pastedText: String, apiKey: String, appState: AppState) {
        // Don't start if already tracking or analyzing
        guard !isAnalyzing else { return }
        
        // Check clipboard fallback: if AX failed last time, check clipboard for edits
        checkClipboardFallback()
        
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
    private func checkClipboardFallback() {
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
        
        // Check if clipboard differs by small edit
        let diff = computeDiff(original: lastPasted, edited: clipboardContent)
        if !diff.isEmpty && !isLargeModification(original: lastPasted, edited: clipboardContent) {
            Log.info("📝 EditTracker: clipboard fallback detected \(diff.count) correction(s)")
            // This was from a previous paste where AX failed — analyze now
            let savedKey = apiKey ?? ""
            let savedAppState = appState
            analyzeEdit(pastedText: lastPasted, editedFieldContent: clipboardContent, apiKey: savedKey, appState: savedAppState)
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
        
        Log.info("📝 EditTracker: keypress detected, waiting \(Int(debounceDelay * 1000))ms...")
    }
    
    /// Called when Enter key is pressed — trigger immediate analysis
    private func handleEnterKey() {
        Log.info("📝 EditTracker: Enter key pressed, triggering immediate analysis")
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
            Log.info("📝 EditTracker: cannot read field content")
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
    
    // MARK: - Character-Level Diff
    
    /// Compute character-level differences between original and edited text.
    /// Returns array of (removed, inserted) string pairs.
    private func computeDiff(original: String, edited: String) -> [(removed: String, inserted: String)] {
        let diff = edited.difference(from: original)
        
        var removals: [String] = []
        var insertions: [String] = []
        
        for change in diff {
            switch change {
            case .remove(_, let element, _):
                removals.append(String(element))
            case .insert(_, let element, _):
                insertions.append(String(element))
            }
        }
        
        // Merge consecutive characters into words/phrases
        let removedText = removals.joined()
        let insertedText = insertions.joined()
        
        if !removedText.isEmpty || !insertedText.isEmpty {
            return [(removed: removedText, inserted: insertedText)]
        }
        
        return []
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
            "model": "llama-3.1-8b-instant",
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
            
            if result == "NONE" || result.isEmpty {
                Log.info("📝 EditTracker: no speech recognition corrections found")
                return
            }
            
            let corrections = self?.parseCorrections(result) ?? []
            
            if corrections.isEmpty {
                Log.info("📝 EditTracker: no valid corrections parsed from: \(result)")
                return
            }
            
            // Apply corrections to dictionary
            DispatchQueue.main.async { [weak self] in
                guard let appState = appState else { return }
                
                for (wrong, right) in corrections {
                    // Add as replacement only (doesn't use Whisper prompt space)
                    appState.dictionary.addReplacement(wrong: wrong, right: right)
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
    private func parseCorrections(_ text: String) -> [(String, String)] {
        var corrections: [(String, String)] = []
        
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
                    
                    // Validate the correction
                    if isValidCorrection(wrong: wrong, right: right) {
                        corrections.append((wrong, right))
                    }
                    break
                }
            }
        }
        
        return corrections
    }
    
    /// Validate that a correction makes sense before adding to dictionary
    private func isValidCorrection(wrong: String, right: String) -> Bool {
        // Both must be non-empty and different
        guard !wrong.isEmpty, !right.isEmpty, wrong != right else { return false }
        
        // Reject if either side contains arrow characters (parsing artifact)
        guard !wrong.contains("→"), !right.contains("→"),
              !wrong.contains("->"), !right.contains("->") else {
            Log.info("📝 EditTracker: rejected (contains arrow): \(wrong) / \(right)")
            return false
        }
        
        // Reject very short words that are likely parsing noise
        guard wrong.count >= 2, right.count >= 2 else {
            Log.info("📝 EditTracker: rejected (too short): \(wrong) / \(right)")
            return false
        }
        
        // Reject if either side is too long (>30 chars — not a single word/phrase)
        guard wrong.count <= 30, right.count <= 30 else {
            Log.info("📝 EditTracker: rejected (too long): \(wrong.prefix(20))... / \(right.prefix(20))...")
            return false
        }
        
        // Reject common LLM noise words
        let noiseWords = ["wrong", "right", "none", "original", "corrected", "text", "word"]
        let lowerWrong = wrong.lowercased()
        let lowerRight = right.lowercased()
        guard !noiseWords.contains(lowerWrong), !noiseWords.contains(lowerRight) else {
            Log.info("📝 EditTracker: rejected (noise word): \(wrong) / \(right)")
            return false
        }
        
        return true
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
