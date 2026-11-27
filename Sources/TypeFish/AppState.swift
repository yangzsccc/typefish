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
    private var recordingID = UUID()
    private var processingTimeout: Timer?
    private let maxProcessingTime: TimeInterval = 30

    /// Custom sounds
    private var startSound: NSSound?
    private var stopSound: NSSound?
    var cancelSound: NSSound?

    /// Floating overlay indicator
    let overlay = OverlayPanel()

    /// Callback to update menu bar icon
    var onStateChange: (() -> Void)?

    init(recorder: AudioRecorder = AudioRecorder()) {
        self.config = AppConfig.load()
        self.recorder = recorder
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
        recordingID = UUID()
        MainActor.assumeIsolated { EditTracker.shared.stopTracking() }

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
        isProcessing = true
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
        let id = recordingID
        guard let audioURL = recorder.stopRecording() else {
            isProcessing = false
            Log.info("⚠️ No audio file from recording")
            statusText = "Ready"
            onStateChange?()
            return
        }

        // Check if audio was silence (prevent Whisper hallucination)
        if recorder.wasSilent() {
            isProcessing = false
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

        // Compress audio for faster upload (WAV → M4A), configurable bitrate
        var uploadURL = processURL
        let bitrate = max(0, config.audioCompressionBitrate)
        if bitrate > 0 {
            if let compressedURL = AudioCompressor.compressToM4A(wavURL: processURL, bitrate: bitrate) {
                uploadURL = compressedURL
            }
        } else {
            Log.info("🗜️ Compression disabled, using WAV upload")
        }
        Log.info("🎧 Audio files: original=\(audioURL.lastPathComponent) processed=\(processURL.lastPathComponent) upload=\(uploadURL.lastPathComponent)")

        isProcessing = true
        statusText = "⏳ Transcribing..."
        onStateChange?()

        overlay.showProcessing()

        // Refuse to paste a late result once this recording times out.
        processingTimeout?.invalidate()
        processingTimeout = Timer.scheduledTimer(withTimeInterval: maxProcessingTime, repeats: false) { [weak self] _ in
            guard let self = self, self.recordingID == id, self.isProcessing else { return }
            self.recordingID = UUID()
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
        // Persist one vocabulary snapshot across the asynchronous transcription and polish callbacks.
        let recordingDictionary = dictionary
        let vocabPrompt = recordingDictionary.whisperPrompt()
        let isTranslating = self.translateMode

        let whisperCallback: (String) -> Void = { [weak self] rawText in
            guard let self = self else { return }
            metrics.whisperTimeMs = Int((CFAbsoluteTimeGetCurrent() - pipelineStartTime) * 1000)

            guard !rawText.isEmpty else {
                metrics.success = false
                metrics.errorType = "no_speech"
                metrics.totalTimeMs = Int((CFAbsoluteTimeGetCurrent() - pipelineStartTime) * 1000)
                MetricsLogger.log(metrics)
                DispatchQueue.main.async {
                    guard self.recordingID == id, self.isProcessing else { return }
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
                metrics.success = false
                metrics.errorType = "hallucination"
                metrics.totalTimeMs = Int((CFAbsoluteTimeGetCurrent() - pipelineStartTime) * 1000)
                MetricsLogger.log(metrics)
                DispatchQueue.main.async {
                    guard self.recordingID == id, self.isProcessing else { return }
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
            let correctedText = recordingDictionary.applyReplacements(rawText)

            // === AI Command Mode: branch here ===
            if isCommandMode {
                DispatchQueue.main.async {
                    guard self.recordingID == id, self.isProcessing else { return }
                    self.statusText = "🤖 AI generating..."
                    self.onStateChange?()

                    // Show command instruction overlay so user can see what was recognized
                    self.overlay.showCommandConfirmation(instruction: correctedText) {
                        // Undo callback: Cmd+Z to revert the paste
                        Log.info("🤖 Undoing AI command paste")
                        PasteService.undo()
                    }
                }

                let commandStartTime = CFAbsoluteTimeGetCurrent()
                AICommand.process(
                    instruction: correctedText,
                    selectedText: capturedSelectedText,
                    fieldContext: fieldContext,
                    apiKey: apiKey
                ) { result in
                    metrics.polishTimeMs = Int((CFAbsoluteTimeGetCurrent() - commandStartTime) * 1000)
                    metrics.totalTimeMs = Int((CFAbsoluteTimeGetCurrent() - pipelineStartTime) * 1000)
                    metrics.success = result?.isEmpty == false
                    if result?.isEmpty != false {
                        metrics.errorType = "command_failed"
                    }
                    MetricsLogger.log(metrics)

                    DispatchQueue.main.async {
                        guard self.recordingID == id, self.isProcessing else { return }
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
                        uploadURL: uploadURL,
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
                guard self.recordingID == id, self.isProcessing else { return }
                self.statusText = "✨ Polishing..."
                self.onStateChange?()
            }

            // Build polisher prompt with dictionary reference + field context + app tone
            var fullSystemPrompt = self.config.polisherSystemPrompt
            if let ref = recordingDictionary.polisherReference() {
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
            let polishStartTime = CFAbsoluteTimeGetCurrent()
            TextPolisher.polish(
                text: correctedText,
                apiKey: apiKey,
                model: self.config.polisherModel,
                systemPrompt: fullSystemPrompt
            ) { polishedText in
                let finalText = recordingDictionary.applyReplacements(polishedText)
                DispatchQueue.main.async {
                    guard self.recordingID == id, self.isProcessing else { return }
                    metrics.polishTimeMs = Int((CFAbsoluteTimeGetCurrent() - polishStartTime) * 1000)
                    metrics.totalTimeMs = Int((CFAbsoluteTimeGetCurrent() - pipelineStartTime) * 1000)

                    // Safety: don't paste empty text
                    guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        Log.info("⚠️ Polished text was empty, skipping paste")
                        metrics.success = false
                        metrics.errorType = "empty_polish"
                        MetricsLogger.log(metrics)
                        self.isProcessing = false
                        self.statusText = "🔇 No speech detected"
                        self.onStateChange?()
                        self.overlay.dismiss()
                        return
                    }

                    // Try to paste to cursor
                    let (dispatch, _) = PasteService.pasteForLearning(finalText) { [weak self] confirmation in
                        let delivered = confirmation?.deliveryConfirmed == true
                        metrics.success = delivered
                        if !delivered {
                            metrics.errorType = "paste_unconfirmed"
                        }
                        MetricsLogger.log(metrics)
                        guard let self, self.recordingID == id else { return }

                        if delivered {
                            self.statusText = PasteDeliveryStatus.confirmed.message
                            self.overlay.showDone()
                            Log.info("Dictation insertion confirmed")
                        } else {
                            self.statusText = PasteDeliveryStatus.unconfirmed.message
                            self.overlay.dismiss()
                            Log.info("Dictation insertion was not visually confirmed; transcript remains on the clipboard")
                        }

                        if let confirmation, let key = self.groqAPIKey {
                            EditTracker.shared.startTracking(
                                pastedText: finalText,
                                confirmedAnchor: confirmation.learningAnchor,
                                apiKey: key,
                                appState: self,
                                historyID: id
                            )
                        }

                        self.onStateChange?()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            guard self.recordingID == id, !self.isRecording && !self.isProcessing else { return }
                            self.statusText = "Ready"
                            self.onStateChange?()
                        }
                    }

                    // Record successful transcription for style learning
                    StyleLearner.shared.recordSuccess(
                        raw: whisperRawText,
                        polished: finalText,
                        appName: PasteService.savedApp?.localizedName ?? "unknown"
                    )

                    self.isProcessing = false
                    self.statusText = dispatch == .sent
                        ? PasteDeliveryStatus.confirming.message
                        : PasteDeliveryStatus.copyAvailable.message
                    self.onStateChange?()

                    if dispatch != .sent {
                        metrics.success = false
                        metrics.errorType = dispatch == .noInput ? "no_paste_target" : "paste_target_changed"
                        MetricsLogger.log(metrics)
                        if dispatch == .noInput {
                            self.overlay.showResult(finalText)
                        } else {
                            self.overlay.dismiss()
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            guard self.recordingID == id, !self.isRecording && !self.isProcessing else { return }
                            self.statusText = "Ready"
                            self.onStateChange?()
                        }
                    }
                }

                // Log transcription for evolution pipeline
                TranscriptionLogger.log(
                    id: id,
                    audioURL: audioURL,
                    uploadURL: uploadURL,
                    whisperRaw: whisperRawText,
                    polished: finalText,
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

    /// Replay the saved audio against today's dictionary. Return the result to History.
    func retryAudio(_ entry: TranscriptionLogger.HistoryEntry, completion: @escaping (String?) -> Void) {
        guard let audio = TranscriptionLogger.savedAudio(for: entry), let key = groqAPIKey else {
            completion(nil)
            return
        }
        let snapshot = dictionary
        let model = config.polisherModel
        var prompt = config.polisherSystemPrompt
        if let reference = snapshot.polisherReference() { prompt += "\n\n" + reference }
        let receive: (String) -> Void = { raw in
            guard !raw.isEmpty, !TextPolisher.isHallucination(raw) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            TextPolisher.polish(text: snapshot.applyReplacements(raw), apiKey: key, model: model, systemPrompt: prompt) { polished in
                let text = snapshot.applyReplacements(polished)
                DispatchQueue.main.async { completion(text.isEmpty ? nil : text) }
            }
        }
        if entry.mode == "translate" {
            WhisperAPI.translate(fileURL: audio, apiKey: key, model: config.whisperModel,
                                 prompt: snapshot.whisperPrompt(), completion: receive)
        } else {
            WhisperAPI.transcribe(fileURL: audio, apiKey: key, model: config.whisperModel, language: config.whisperLanguage,
                                  prompt: snapshot.whisperPrompt(), completion: receive)
        }
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Shared Settings & Dictionary Actions

    func saveConfig() {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/typefish/config.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(config) {
            try? data.write(to: configURL)
        }
    }

    func reloadDictionary() {
        dictionary = CustomDictionary.load()
        onStateChange?()
    }

    func setPreferredMicrophone(_ microphone: String?) {
        config.preferredMicrophone = microphone
        saveConfig()
        recorder.preferredMicrophone = microphone
        onStateChange?()
    }

    func setAudioCompressionBitrate(_ bitrate: Int) {
        config.audioCompressionBitrate = bitrate
        saveConfig()
        onStateChange?()
    }

    static func compressionTitle(for bitrate: Int) -> String {
        switch bitrate {
        case 0: return "Off (WAV)"
        case 32000: return "Aggressive (32kbps)"
        case 48000: return "Fast (48kbps)"
        case 64000: return "Balanced (64kbps)"
        case 96000: return "Quality (96kbps)"
        default: return "Custom (\(bitrate / 1000)kbps)"
        }
    }

    func addDictionaryHint(_ word: String) {
        dictionary.addHint(word)
        onStateChange?()
    }

    func updateDictionaryHint(oldValue: String, newValue: String) {
        dictionary.updateHint(oldValue: oldValue, newValue: newValue)
        onStateChange?()
    }

    func removeDictionaryHint(_ word: String) {
        dictionary.removeHint(word)
        onStateChange?()
    }

    func addDictionaryVocabulary(_ word: String) {
        dictionary.addVocabulary(word)
        onStateChange?()
    }

    func updateDictionaryVocabulary(oldValue: String, newValue: String) {
        dictionary.updateVocabulary(oldValue: oldValue, newValue: newValue)
        onStateChange?()
    }

    func removeDictionaryVocabulary(_ word: String) {
        dictionary.removeVocabulary(word)
        onStateChange?()
    }

    func addDictionaryReplacement(wrong: String, right: String, source: ReplacementSource = .manual) {
        dictionary.addReplacement(wrong: wrong, right: right, source: source)
        onStateChange?()
    }

    func updateDictionaryReplacement(oldWrong: String, wrong: String, right: String, source: ReplacementSource? = nil) {
        dictionary.updateReplacement(oldWrong: oldWrong, wrong: wrong, right: right, source: source)
        onStateChange?()
    }

    func removeDictionaryReplacement(_ wrong: String) {
        dictionary.removeReplacement(wrong)
        onStateChange?()
    }

    // MARK: - Dictionary File Watching

    private func watchDictionaryFile() {
        let url = CustomDictionary.fileURL
        let fd = open(url.deletingLastPathComponent().path, O_EVTONLY)
        guard fd >= 0 else { return }
        // Atomic saves replace the file's inode. The containing directory survives each save.
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename], queue: .main
        )
        var previousData = try? Data(contentsOf: url)
        source.setEventHandler { [weak self] in
            guard let self, let data = try? Data(contentsOf: url), data != previousData,
                  (try? JSONDecoder().decode(CustomDictionary.self, from: data)) != nil else { return }
            previousData = data
            self.dictionary = CustomDictionary.load(from: url)
            self.onStateChange?()
        }
        source.setCancelHandler { close(fd) }
        dictFileMonitor = source
        source.resume()
    }

    deinit { dictFileMonitor?.cancel() }

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
