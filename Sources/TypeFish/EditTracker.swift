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
    private let pollInterval: TimeInterval = 2
    
    private var timer: Timer?
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
    
    private init() {}
    
    // MARK: - Public API
    
    /// Start tracking after a successful paste.
    /// Call this from AppState after PasteService.paste() returns true.
    func startTracking(pastedText: String, apiKey: String, appState: AppState) {
        // Don't start if already tracking or analyzing
        guard !isAnalyzing else { return }
        stopTracking()
        
        // Skip very short text (not worth tracking)
        guard pastedText.count >= 4 else { return }
        
        // Delay to let paste settle, then try to verify with retries
        self.trackedText = pastedText
        self.apiKey = apiKey
        self.appState = appState
        self.verifyAndStartPolling(pastedText: pastedText, attempt: 1)
    }
    
    /// Stop tracking (called on timeout, new recording, or edit detected)
    func stopTracking() {
        timer?.invalidate()
        timer = nil
        trackedText = nil
        trackingStartTime = nil
        apiKey = nil
        appState = nil
        lastChangeTime = nil
        lastFieldContent = nil
    }
    
    // MARK: - Startup Verification
    
    private let maxVerifyAttempts = 3
    private let verifyInterval: TimeInterval = 0.8  // seconds between retries
    
    private func verifyAndStartPolling(pastedText: String, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + verifyInterval) { [weak self] in
            guard let self = self, self.trackedText != nil else { return }
            
            let fieldContent = ContextReader.readFullContent()
            
            if let content = fieldContent, content.contains(pastedText) {
                // Found our text — start normal tracking
                self.trackingStartTime = Date()
                Log.info("📝 EditTracker: verified text in field (attempt \(attempt)), monitoring \(pastedText.count) chars")
                self.startPollingTimer()
                return
            }
            
            if attempt < self.maxVerifyAttempts {
                // Retry — app might not have rendered the paste yet
                Log.info("📝 EditTracker: text not found yet (attempt \(attempt)/\(self.maxVerifyAttempts)), retrying...")
                self.verifyAndStartPolling(pastedText: pastedText, attempt: attempt + 1)
                return
            }
            
            // All retries exhausted — check if we can read the field at all
            if fieldContent != nil {
                // We CAN read the field, but our text isn't there
                // (common with Electron apps like Discord, Slack, VS Code)
                // Start tracking anyway — compare against pasted text directly
                self.trackingStartTime = Date()
                Log.info("📝 EditTracker: text not verified but field readable, monitoring in relaxed mode")
                self.startPollingTimer()
            } else {
                // Can't read the field at all — give up
                Log.info("📝 EditTracker: cannot read field after \(self.maxVerifyAttempts) attempts, skipping")
                self.stopTracking()
            }
        }
    }
    
    private func startPollingTimer() {
        self.timer = Timer.scheduledTimer(withTimeInterval: self.pollInterval, repeats: true) { [weak self] _ in
            self?.pollForEdits()
        }
    }
    
    // MARK: - Polling
    
    private func pollForEdits() {
        guard let tracked = trackedText else {
            stopTracking()
            return
        }
        
        // Check total timeout
        guard let startTime = trackingStartTime,
              Date().timeIntervalSince(startTime) < trackingDuration else {
            // Timeout — if there's a pending stable edit, analyze it
            if let lastContent = lastFieldContent, lastChangeTime != nil {
                Log.info("📝 EditTracker: timeout with pending edit, analyzing")
                triggerAnalysis(pastedText: tracked, editedField: lastContent)
            } else {
                Log.info("📝 EditTracker: timeout, no edit detected")
                stopTracking()
            }
            return
        }
        
        // Read current field content
        guard let currentContent = ContextReader.readFullContent() else {
            Log.info("📝 EditTracker: lost focus, stopping")
            stopTracking()
            return
        }
        
        // Field cleared
        guard !currentContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Log.info("📝 EditTracker: field cleared, stopping")
            stopTracking()
            return
        }
        
        // Content drastically different — but only for longer texts
        // Short texts (< 20 chars) can legitimately change a lot with one word edit
        if tracked.count > 20 && currentContent.count < tracked.count / 5 {
            Log.info("📝 EditTracker: large change (\(currentContent.count) vs \(tracked.count)), not a correction")
            stopTracking()
            return
        }
        
        // If pasted text still present verbatim, no edit yet — reset debounce
        if currentContent.contains(tracked) {
            lastChangeTime = nil
            lastFieldContent = nil
            return
        }
        
        // Text has changed! But don't analyze immediately — debounce.
        let now = Date()
        
        // If content changed since last poll, reset the stability timer
        if lastFieldContent != currentContent {
            if lastFieldContent == nil {
                Log.info("📝 EditTracker: edit started, waiting for user to finish...")
            }
            lastChangeTime = now
            lastFieldContent = currentContent
            return  // Keep polling, user is still editing
        }
        
        // Content same as last poll — check if stable long enough
        guard let changeTime = lastChangeTime else { return }
        
        if now.timeIntervalSince(changeTime) >= stabilizeDelay {
            // Text has been stable for 3+ seconds — user is done editing
            Log.info("📝 EditTracker: edit stabilized after \(String(format: "%.1f", now.timeIntervalSince(changeTime)))s")
            triggerAnalysis(pastedText: tracked, editedField: currentContent)
        }
        // Otherwise: still waiting for stability
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
        
        let userMessage = """
        TEXT A (original STT output):
        \(pastedText)
        
        TEXT B (after user's manual correction):
        \(cappedField)
        """
        
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
