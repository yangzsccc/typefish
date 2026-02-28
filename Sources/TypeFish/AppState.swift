import Foundation
import AppKit

/// Main app state and pipeline orchestrator.
/// Manages: recording toggle, transcription, polishing, pasting.
class AppState: ObservableObject {
    
    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var statusText = "Ready"
    
    /// When true, current recording will be translated to English
    private(set) var translateMode = false
    
    /// Public accessor for menu bar icon
    var isTranslateMode: Bool { translateMode }
    
    let config: AppConfig
    let recorder = AudioRecorder()
    let groqAPIKey: String?
    
    /// Custom dictionary for vocabulary hints and replacements
    var dictionary: CustomDictionary
    
    /// File monitor for auto-reloading dictionary
    private var dictFileMonitor: DispatchSourceFileSystemObject?
    
    /// Custom sounds
    private var startSound: NSSound?
    private var stopSound: NSSound?
    private var cancelSound: NSSound?
    
    /// Floating overlay indicator
    let overlay = OverlayPanel()
    
    /// Callback to update menu bar icon
    var onStateChange: (() -> Void)?
    
    init() {
        self.config = AppConfig.load()
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
    }
    
    /// Toggle recording on/off (normal transcribe)
    func toggleRecording() {
        if isRecording {
            stopAndProcess()
        } else {
            translateMode = false
            startRecording()
        }
    }
    
    /// Toggle recording in translate-to-English mode
    func toggleTranslateRecording() {
        if isRecording {
            stopAndProcess()
        } else {
            translateMode = true
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
        guard !isProcessing else {
            Log.info("⚠️ Still processing previous recording, please wait")
            return
        }
        
        // Save reference to the app user is typing in BEFORE we do anything
        PasteService.saveFrontmostApp()
        
        // Wire up audio level to overlay
        recorder.onAudioLevel = { [weak self] rms in
            self?.overlay.updateAudioLevel(rms)
        }
        
        let success = recorder.startRecording()
        if success {
            isRecording = true
            statusText = translateMode ? "🌐 Recording (Translate)..." : "🔴 Recording..."
            onStateChange?()
            startSound?.play()
            overlay.showRecording(translate: translateMode)
        }
    }
    
    private func stopAndProcess() {
        // Brief delay after pressing stop to capture trailing speech
        isRecording = false
        statusText = "⏳ Finishing..."
        onStateChange?()
        
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
        
        // Always play stop sound when recording ends
        stopSound?.play()
        
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
        
        isProcessing = true
        statusText = "⏳ Transcribing..."
        onStateChange?()
        
        overlay.showProcessing()
        
        guard let apiKey = groqAPIKey else {
            Log.info("❌ No API key, cannot transcribe")
            isProcessing = false
            statusText = "❌ No API key"
            onStateChange?()
            cleanup(audioURL)
            return
        }
        
        // Pipeline: Transcribe/Translate → Polish → Paste
        let vocabPrompt = dictionary.whisperPrompt()
        let isTranslating = self.translateMode
        
        let whisperCallback: (String) -> Void = { [weak self] rawText in
            guard let self = self else { return }
            
            guard !rawText.isEmpty else {
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.statusText = "❌ No speech detected"
                    self.onStateChange?()
                }
                self.cleanup(audioURL)
                return
            }
            
            // Apply dictionary replacements
            let correctedText = self.dictionary.applyReplacements(rawText)
            
            DispatchQueue.main.async {
                self.statusText = "✨ Polishing..."
                self.onStateChange?()
            }
            
            // Build polisher prompt with dictionary reference
            var fullSystemPrompt = self.config.polisherSystemPrompt
            if let ref = self.dictionary.polisherReference() {
                fullSystemPrompt += "\n\n" + ref
            }
            
            // Polish the transcript
            TextPolisher.polish(
                text: correctedText,
                apiKey: apiKey,
                model: self.config.polisherModel,
                systemPrompt: fullSystemPrompt
            ) { polishedText in
                DispatchQueue.main.async {
                    // Try to paste to cursor
                    let pasted = PasteService.paste(polishedText)
                    
                    self.isProcessing = false
                    self.statusText = "✅ Done"
                    self.onStateChange?()
                    
                    if pasted {
                        self.overlay.showDone()
                    } else {
                        // No text input focused — show result panel with copy button
                        self.overlay.showResult(polishedText)
                    }
                    
                    // Reset status after 2 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        if !self.isRecording && !self.isProcessing {
                            self.statusText = "Ready"
                            self.onStateChange?()
                        }
                    }
                }
                
                self.cleanup(audioURL)
            }
        }
        
        // Call the appropriate Whisper endpoint
        if isTranslating {
            Log.info("🌐 Translate mode: will translate to English")
            WhisperAPI.translate(fileURL: audioURL, apiKey: apiKey, model: config.whisperModel, prompt: vocabPrompt, completion: whisperCallback)
        } else {
            WhisperAPI.transcribe(fileURL: audioURL, apiKey: apiKey, model: config.whisperModel, language: config.whisperLanguage, prompt: vocabPrompt, completion: whisperCallback)
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
