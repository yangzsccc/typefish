import Foundation
import AppKit

/// Main app state and pipeline orchestrator.
/// Manages: recording toggle, transcription, polishing, pasting.
class AppState: ObservableObject {
    
    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var statusText = "Ready"
    
    let config: AppConfig
    let recorder = AudioRecorder()
    let groqAPIKey: String?
    
    /// Callback to update menu bar icon
    var onStateChange: (() -> Void)?
    
    init() {
        self.config = AppConfig.load()
        self.groqAPIKey = AppState.loadAPIKey()
        
        if groqAPIKey != nil {
            Log.info("✅ Groq API key loaded")
        } else {
            Log.info("❌ No Groq API key found! Set GROQ_API_KEY env var or create ~/.config/typefish/groq_key")
        }
    }
    
    /// Toggle recording on/off
    func toggleRecording() {
        if isRecording {
            stopAndProcess()
        } else {
            startRecording()
        }
    }
    
    // MARK: - Recording
    
    private func startRecording() {
        guard !isProcessing else {
            Log.info("⚠️ Still processing previous recording, please wait")
            return
        }
        
        let success = recorder.startRecording()
        if success {
            isRecording = true
            statusText = "🔴 Recording..."
            onStateChange?()
            // Play start sound
            NSSound(named: "Tink")?.play()
        }
    }
    
    private func stopAndProcess() {
        guard let audioURL = recorder.stopRecording() else {
            Log.info("⚠️ No audio file from recording")
            isRecording = false
            statusText = "Ready"
            onStateChange?()
            return
        }
        
        isRecording = false
        isProcessing = true
        statusText = "⏳ Transcribing..."
        onStateChange?()
        
        // Play stop sound
        NSSound(named: "Pop")?.play()
        
        guard let apiKey = groqAPIKey else {
            Log.info("❌ No API key, cannot transcribe")
            isProcessing = false
            statusText = "❌ No API key"
            onStateChange?()
            cleanup(audioURL)
            return
        }
        
        // Pipeline: Transcribe → Polish → Paste
        WhisperAPI.transcribe(fileURL: audioURL, apiKey: apiKey, model: config.whisperModel) { [weak self] rawText in
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
            
            DispatchQueue.main.async {
                self.statusText = "✨ Polishing..."
                self.onStateChange?()
            }
            
            // Polish the transcript
            TextPolisher.polish(
                text: rawText,
                apiKey: apiKey,
                model: self.config.polisherModel,
                systemPrompt: self.config.polisherSystemPrompt
            ) { polishedText in
                DispatchQueue.main.async {
                    // Paste to cursor
                    PasteService.paste(polishedText)
                    
                    self.isProcessing = false
                    self.statusText = "✅ Done"
                    self.onStateChange?()
                    
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
    }
    
    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
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
