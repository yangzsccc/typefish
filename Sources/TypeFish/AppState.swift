import Foundation
import AppKit

/// Main app state and pipeline orchestrator.
/// Manages: recording toggle, transcription, polishing, pasting.
class AppState: ObservableObject {
    
    @Published var isRecording = false
    @Published var isProcessing = false {
        didSet {
            if !isProcessing {
                processingTimeout?.invalidate()
                processingTimeout = nil
            }
        }
    }
    @Published var statusText = "Ready"
    
    /// When true, current recording will be translated to English
    private(set) var translateMode = false
    
    /// When true, current recording is AI command mode (generate/edit)
    private(set) var commandMode = false
    
    /// Selected text captured when command mode started
    private var commandSelectedText: String?
    
    /// Public accessor for menu bar icon
    var isTranslateMode: Bool { translateMode }
    
    /// Public accessor for command mode
    var isCommandMode: Bool { commandMode }
    
    var config: AppConfig
    let recorder: AudioRecorder
    let groqAPIKey: String?
    
    /// Custom dictionary for vocabulary hints and replacements
    var dictionary: CustomDictionary
    
    /// File monitor for auto-reloading dictionary
    private var dictFileMonitor: DispatchSourceFileSystemObject?
    
    /// Safety timeout to prevent permanent processing stuck
    private var processingTimeout: Timer?
    private let maxProcessingTime: TimeInterval = 60
    
    /// Custom sounds
    private var startSound: NSSound?
    private var stopSound: NSSound?
    var cancelSound: NSSound?
    
    /// Floating overlay indicator
    let overlay = OverlayPanel()
    
    /// Callback to update menu bar icon
    var onStateChange: (() -> Void)?
    
    init() {
        self.config = AppConfig.load()
        self.recorder = AudioRecorder()
        self.recorder.preferredMicrophone = config.preferredMicrophone
        // Lock preferred mic as system default BEFORE any engine access
        // This prevents Bluetooth headphones from being activated as input
        self.recorder.lockPreferredMicrophone()
        self.groqAPIKey = AppState.loadAPIKey()
        self.dictionary = CustomDictionary.load()
        
        // Load custom sounds
        self.startSound = AppState.loadSound("start")
        self.stopSound = AppState.loadSound("stop")
        self.cancelSound = AppState.loadSound("cancel")
        
        if groqAPIKey != nil {
            Log.info("✅ Groq API key loaded")
        } else {
            Log.info("❌ No Groq API key found! Set GROQ_API_KEY env var or create ~/.config/typefish/groq_key")
        }
        
        watchDictionaryFile()
        
        // Start audio engine in background — keeps running so recording is instant
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.recorder.startEngine()
        }
    }
    
    /// Toggle recording on/off (normal transcribe)
    func toggleRecording() {
        if isRecording {
            stopAndProcess()
        } else {
            translateMode = false
            commandMode = false
            commandSelectedText = nil
            startRecording()
        }
    }
    
    /// Toggle recording in translate-to-English mode
    func toggleTranslateRecording() {
        if isRecording {
            stopAndProcess()
        } else {
            translateMode = true
            commandMode = false
            startRecording()
        }
    }
    
    /// Toggle recording in AI command mode (generate/edit content)
    func toggleCommandRecording() {
        if isRecording {
            stopAndProcess()
        } else {
            translateMode = false
            commandMode = true
            
            // Capture selected text NOW before recording starts
            // Save frontmost app first
            PasteService.saveFrontmostApp()
            
            // Try AX API first, then clipboard simulation
            commandSelectedText = ContextReader.readSelectedText()
            if commandSelectedText == nil {
                commandSelectedText = ContextReader.readSelectedTextViaClipboard()
            }
            
            if let sel = commandSelectedText {
                Log.info("🤖 AI Command: captured \(sel.count) chars of selected text")
            } else {
                Log.info("🤖 AI Command: no text selected (will generate from scratch)")
            }
            
            startRecording()
        }
    }
    
    /// Cancel current recording without processing
    func cancelRecording() {
        guard isRecording else { return }
        
        Log.info("🚫 Recording cancelled by user")
        
        // Stop the recorder immediately, discard the file
        if let audioURL = recorder.stopRecording() {
            cleanup(audioURL)
        }
        
        isRecording = false
        isProcessing = false
        statusText = "❌ Cancelled"
        onStateChange?()
        
        cancelSound?.play()
        overlay.dismiss()
        
        // Reset status after 1.5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            if !self.isRecording && !self.isProcessing {
                self.statusText = "Ready"
                self.onStateChange?()
            }
        }
    }
    
    // MARK: - Recording
    
    private func startRecording() {
        if isProcessing {
            // If processing has been stuck for >10s, force-reset on hotkey press
            // Timer fires at start+30s, so fireDate-now < 20 means >10s elapsed
            if let timeout = processingTimeout, timeout.fireDate.timeIntervalSinceNow < 20 {
                Log.info("⚠️ Force-resetting stuck processing state (user pressed hotkey)")
                isProcessing = false
                overlay.dismiss()
            } else {
                Log.info("⚠️ Still processing previous recording, please wait")
                return
            }
        }
        
        // Stop any edit tracking from previous recording
        EditTracker.shared.stopTracking()
        
        // Save reference to the app user is typing in BEFORE we do anything
        PasteService.saveFrontmostApp()
        
        // Show UI IMMEDIATELY — don't wait for engine startup
        isRecording = true
        if commandMode {
            statusText = "🤖 Recording (AI Command)..."
        } else if translateMode {
            statusText = "🌐 Recording (Translate)..."
        } else {
            statusText = "🔴 Recording..."
        }
        onStateChange?()
        startSound?.play()
        if commandMode {
            overlay.showRecording(command: true)
        } else {
            overlay.showRecording(translate: translateMode)
        }
        
        // Wire up audio level to overlay
        recorder.onAudioLevel = { [weak self] rms in
            self?.overlay.updateAudioLevel(rms)
        }
        
        // Start recording — instant because engine is already running
        // Just creates a file for the tap to write to
        let success = recorder.startRecording()
        if !success {
            Log.info("❌ Failed to start recording")
            isRecording = false
            statusText = "Ready"
            onStateChange?()
            overlay.dismiss()
        }
    }
    
    private func stopAndProcess() {
        // Update UI immediately on stop press
        isRecording = false
        stopSound?.play()
        statusText = "⏳ Processing..."
        onStateChange?()
        overlay.showProcessing()
        
        // Brief delay after pressing stop to capture trailing speech
        Log.info("⏱️ Recording tail buffer (400ms)...")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self else {
                Log.info("❌ Self deallocated during tail buffer")
                return
            }
            self.finalizeRecording()
        }
    }
    
    private func finalizeRecording() {
        guard let audioURL = recorder.stopRecording() else {
            Log.info("⚠️ No audio file from recording")
            statusText = "Ready"
            onStateChange?()
            return
        }
        
        // Check if audio was silence (prevent Whisper hallucination)
        if recorder.wasSilent() {
            statusText = "🔇 No speech"
            onStateChange?()
            overlay.dismiss()
            cleanup(audioURL)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if !self.isRecording && !self.isProcessing {
                    self.statusText = "Ready"
                    self.onStateChange?()
                }
            }
            return
        }
        
        // Trim trailing silence to prevent Whisper hallucination
        let processURL: URL
        if let trimmedURL = AudioRecorder.trimTrailingSilence(fileURL: audioURL) {
            processURL = trimmedURL
        } else {
            processURL = audioURL
        }
        
        // Compress audio for faster upload (WAV → M4A, ~10x smaller)
        var uploadURL = processURL
        if let compressedURL = AudioCompressor.compressToM4A(wavURL: processURL) {
            uploadURL = compressedURL
        }
        
        isProcessing = true
        statusText = "⏳ Transcribing..."
        onStateChange?()
        
        overlay.showProcessing()
        
        // Safety: force-reset after 60s to prevent permanent stuck
        processingTimeout?.invalidate()
        processingTimeout = Timer.scheduledTimer(withTimeInterval: maxProcessingTime, repeats: false) { [weak self] _ in
            guard let self = self, self.isProcessing else { return }
            Log.info("⚠️ Processing timeout (\(Int(self.maxProcessingTime))s) — force resetting")
            self.isProcessing = false
            self.statusText = "⚠️ Timeout"
            self.onStateChange?()
            self.overlay.dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if !self.isRecording && !self.isProcessing {
                    self.statusText = "Ready"
                    self.onStateChange?()
                }
            }
        }
        
        guard let apiKey = groqAPIKey else {
            Log.info("❌ No API key, cannot transcribe")
            isProcessing = false
            statusText = "❌ No API key"
            onStateChange?()
            cleanup(audioURL)
            return
        }
        
        // Read context from current text field (before transcription starts)
        let fieldContext = ContextReader.readContext()
        
        // Capture mode flags before they get reset
        let isCommandMode = self.commandMode
        let capturedSelectedText = self.commandSelectedText
        
        // Metrics tracking
        let pipelineStartTime = CFAbsoluteTimeGetCurrent()
        var metrics = MetricsLogger.PipelineMetrics()
        metrics.mode = isCommandMode ? "command" : (self.translateMode ? "translate" : "transcribe")
        metrics.audioSizeKB = (try? FileManager.default.attributesOfItem(atPath: processURL.path)[.size] as? Int).flatMap { $0 / 1024 } ?? 0
        metrics.whisperModel = self.config.whisperModel
        metrics.polishModel = self.config.polisherModel
        
        // Pipeline: Transcribe/Translate → Polish → Paste (or AI Command)
        let vocabPrompt = dictionary.whisperPrompt()
        let isTranslating = self.translateMode
        
        let whisperCallback: (String) -> Void = { [weak self] rawText in
            guard let self = self else { return }
            
            guard !rawText.isEmpty else {
                metrics.success = false
                metrics.errorType = "no_speech"
                metrics.totalTimeMs = Int((CFAbsoluteTimeGetCurrent() - pipelineStartTime) * 1000)
                MetricsLogger.log(metrics)
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.statusText = "❌ No speech detected"
                    self.onStateChange?()
                    self.overlay.dismiss()
                }
                self.cleanup(audioURL)
                if processURL != audioURL { self.cleanup(processURL) }; if uploadURL != processURL { self.cleanup(uploadURL) }
                return
            }
            
            // Check for known Whisper hallucinations
            if TextPolisher.isHallucination(rawText) {
                Log.info("🔇 Whisper hallucination detected: \(rawText.prefix(50))...")
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.statusText = "🔇 No speech detected"
                    self.onStateChange?()
                    self.overlay.dismiss()
                }
                self.cleanup(audioURL)
                if processURL != audioURL { self.cleanup(processURL) }; if uploadURL != processURL { self.cleanup(uploadURL) }
                return
            }
            
            // Save raw text for logging
            let whisperRawText = rawText
            
            // Apply dictionary replacements
            let correctedText = self.dictionary.applyReplacements(rawText)
            
            // === AI Command Mode: branch here ===
            if isCommandMode {
                DispatchQueue.main.async {
                    self.statusText = "🤖 AI generating..."
                    self.onStateChange?()
                    
                    // Show command instruction overlay so user can see what was recognized
                    self.overlay.showCommandConfirmation(instruction: correctedText) {
                        // Undo callback: Cmd+Z to revert the paste
                        Log.info("🤖 Undoing AI command paste")
                        PasteService.undo()
                    }
                }
                
                AICommand.process(
                    instruction: correctedText,
                    selectedText: capturedSelectedText,
                    fieldContext: fieldContext,
                    apiKey: apiKey
                ) { result in
                    DispatchQueue.main.async {
                        guard let generated = result, !generated.isEmpty else {
                            self.isProcessing = false
                            self.statusText = "❌ AI failed"
                            self.onStateChange?()
                            self.overlay.dismissCommandWindow()
                            return
                        }
                        
                        // Paste the generated content
                        let pasted = PasteService.paste(generated)
                        
                        self.isProcessing = false
                        self.statusText = "✅ Done"
                        self.onStateChange?()
                        
                        if !pasted {
                            self.overlay.dismissCommandWindow()
                            self.overlay.showResult(generated)
                        }
                        // Command notification stays visible with Undo button
                        
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            if !self.isRecording && !self.isProcessing {
                                self.statusText = "Ready"
                                self.onStateChange?()
                            }
                        }
                    }
                    
                    // Log it
                    TranscriptionLogger.log(
                        audioURL: audioURL,
                        whisperRaw: whisperRawText,
                        polished: result ?? "",
                        mode: "command",
                        whisperModel: self.config.whisperModel,
                        polisherModel: "llama-3.3-70b-versatile",
                        fieldContext: fieldContext
                    )
                    
                    self.cleanup(audioURL)
                    if processURL != audioURL { self.cleanup(processURL) }; if uploadURL != processURL { self.cleanup(uploadURL) }
                }
                return  // Don't fall through to normal polish pipeline
            }
            
            DispatchQueue.main.async {
                self.statusText = "✨ Polishing..."
                self.onStateChange?()
            }
            
            // Build polisher prompt with dictionary reference + field context + app tone
            var fullSystemPrompt = self.config.polisherSystemPrompt
            if let ref = self.dictionary.polisherReference() {
                fullSystemPrompt += "\n\n" + ref
            }
            if let toneMod = AppToneAdapter.tonePromptModifier() {
                fullSystemPrompt += "\n\n" + toneMod
                Log.info("🎭 Tone: \(AppToneAdapter.detectTone().rawValue)")
            }
            if let personalization = StyleLearner.shared.polisherPersonalization() {
                fullSystemPrompt += "\n\n" + personalization
            }
            if let ctx = fieldContext, !ctx.isEmpty {
                fullSystemPrompt += "\n\nThe user is typing into a text field that already contains the following text (before the cursor). Use this context to make the new transcription flow naturally — match the tone, avoid repeating what's already written, and connect smoothly:\n<existing_text>\n\(ctx)\n</existing_text>"
            }
            
            // Polish the transcript
            TextPolisher.polish(
                text: correctedText,
                apiKey: apiKey,
                model: self.config.polisherModel,
                systemPrompt: fullSystemPrompt
            ) { polishedText in
                DispatchQueue.main.async {
                    // Apply reverse replacements AFTER polishing
                    // Catches cases where polisher translates English to Chinese
                    let finalText = self.dictionary.applyReplacements(polishedText)
                    
                    // Safety: don't paste empty text
                    guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        Log.info("⚠️ Polished text was empty, skipping paste")
                        self.isProcessing = false
                        self.statusText = "🔇 No speech detected"
                        self.onStateChange?()
                        self.overlay.dismiss()
                        return
                    }
                    
                    // Try to paste to cursor
                    let pasted = PasteService.paste(finalText)
                    
                    // Record successful transcription for style learning
                    StyleLearner.shared.recordSuccess(
                        raw: whisperRawText,
                        polished: finalText,
                        appName: PasteService.savedApp?.localizedName ?? "unknown"
                    )
                    
                    self.isProcessing = false
                    self.statusText = "✅ Done"
                    self.onStateChange?()
                    
                    if pasted {
                        self.overlay.showDone()
                        
                        // Start edit tracking for auto-dictionary learning
                        if let key = self.groqAPIKey {
                            EditTracker.shared.startTracking(
                                pastedText: finalText,
                                apiKey: key,
                                appState: self
                            )
                        }
                    } else {
                        // No text input focused — show result panel with copy button
                        self.overlay.showResult(finalText)
                    }
                    
                    // Reset status after 2 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        if !self.isRecording && !self.isProcessing {
                            self.statusText = "Ready"
                            self.onStateChange?()
                        }
                    }
                }
                
                // Log transcription for evolution pipeline
                TranscriptionLogger.log(
                    audioURL: audioURL,
                    whisperRaw: whisperRawText,
                    polished: polishedText,
                    mode: isTranslating ? "translate" : "transcribe",
                    whisperModel: self.config.whisperModel,
                    polisherModel: self.config.polisherModel,
                    fieldContext: fieldContext
                )
                
                self.cleanup(audioURL)
                if processURL != audioURL { self.cleanup(processURL) }; if uploadURL != processURL { self.cleanup(uploadURL) }
            }
        }
        
        // Call the appropriate Whisper endpoint (use compressed file if available)
        if isTranslating {
            Log.info("🌐 Translate mode: will translate to English")
            WhisperAPI.translate(fileURL: uploadURL, apiKey: apiKey, model: config.whisperModel, prompt: vocabPrompt, completion: whisperCallback)
        } else {
            WhisperAPI.transcribe(fileURL: uploadURL, apiKey: apiKey, model: config.whisperModel, language: config.whisperLanguage, prompt: vocabPrompt, completion: whisperCallback)
        }
    }
    
    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
    
    // MARK: - Dictionary File Watching
    
    private func watchDictionaryFile() {
        let path = CustomDictionary.fileURL.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            Log.info("⚠️ Cannot watch dictionary file")
            return
        }
        
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        
        source.setEventHandler { [weak self] in
            // Small delay to let file writes complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self?.dictionary = CustomDictionary.load()
            }
        }
        
        source.setCancelHandler {
            close(fd)
        }
        
        source.resume()
        self.dictFileMonitor = source
        Log.info("👁️ Watching dictionary file for changes")
    }
    
    // MARK: - Sound Loading
    
    /// Load a custom sound file from the app bundle Resources or fallback locations
    private static func loadSound(_ name: String) -> NSSound? {
        let paths = [
            // Inside .app bundle
            Bundle.main.bundlePath + "/Contents/Resources/\(name).aiff",
            // Development: next to source
            Bundle.main.bundlePath + "/../Sources/TypeFish/Sounds/\(name).aiff",
            // Development: relative to working directory
            FileManager.default.currentDirectoryPath + "/Sources/TypeFish/Sounds/\(name).aiff",
            // Absolute fallback
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("typefish/Sources/TypeFish/Sounds/\(name).aiff").path
        ]
        
        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                if let sound = NSSound(contentsOfFile: path, byReference: true) {
                    Log.info("🔔 Loaded sound: \(name) from \(path)")
                    return sound
                }
            }
        }
        
        Log.info("⚠️ Sound not found: \(name), using system fallback")
        return NSSound(named: name == "start" ? "Tink" : "Pop")
    }
    
    // MARK: - API Key Loading
    
    /// Load Groq API key from env or file
    private static func loadAPIKey() -> String? {
        // 1. Environment variable
        if let key = ProcessInfo.processInfo.environment["GROQ_API_KEY"],
           !key.isEmpty {
            Log.info("🔑 API key from env GROQ_API_KEY")
            return key
        }
        
        // 2. TypeFish config file
        let typefishKeyPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/typefish/groq_key")
        if let key = readKeyFile(typefishKeyPath) {
            Log.info("🔑 API key from ~/.config/typefish/groq_key")
            return key
        }
        
        // 3. Shared with NoClue
        let noclueKeyPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/noclue/groq_key")
        if let key = readKeyFile(noclueKeyPath) {
            Log.info("🔑 API key from ~/.config/noclue/groq_key (shared)")
            return key
        }
        
        return nil
    }
    
    private static func readKeyFile(_ url: URL) -> String? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        // Handle formats: raw key, KEY="value", KEY=value
        let cleaned = content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "=").last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            ?? content.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return cleaned.isEmpty ? nil : cleaned
    }
}
