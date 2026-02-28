import Foundation

/// App configuration, loaded from config.json or defaults
struct AppConfig: Codable {
    var whisperModel: String = "whisper-large-v3-turbo"
    var polisherModel: String = "llama-3.3-70b-versatile"
    var polisherSystemPrompt: String = """
        You are a minimal text editor. Fix only: stutters, repetitions, and self-corrections. \
        Keep the original wording, structure, and language. Do not rewrite, do not add formality, \
        do not add formatting. If the input is already clean, output it unchanged. \
        Output only the cleaned text, nothing else.
        """
    var audioSampleRate: Double = 16000
    
    /// Load config from config.json next to the executable, or use defaults
    static func load() -> AppConfig {
        // Try multiple locations
        let paths = [
            // Next to executable
            Bundle.main.bundlePath + "/config.json",
            // Project directory
            FileManager.default.currentDirectoryPath + "/config.json",
            // Home config
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/typefish/config.json").path
        ]
        
        for path in paths {
            if let data = FileManager.default.contents(atPath: path) {
                do {
                    let config = try JSONDecoder().decode(AppConfig.self, from: data)
                    Log.info("✅ Loaded config from \(path)")
                    return config
                } catch {
                    Log.info("⚠️ Failed to parse \(path): \(error.localizedDescription)")
                }
            }
        }
        
        Log.info("📋 Using default config")
        return AppConfig()
    }
}
