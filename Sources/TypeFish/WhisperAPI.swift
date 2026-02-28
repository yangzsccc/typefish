import Foundation

/// Transcribes/translates audio files using Groq's Whisper API.
enum WhisperAPI {
    
    /// Transcribe an audio file (keep original language)
    static func transcribe(
        fileURL: URL,
        apiKey: String,
        model: String = "whisper-large-v3-turbo",
        language: String? = nil,
        prompt: String? = nil,
        completion: @escaping (String) -> Void
    ) {
        callWhisper(
            endpoint: "transcriptions",
            fileURL: fileURL,
            apiKey: apiKey,
            model: model,
            language: language,
            prompt: prompt,
            completion: completion
        )
    }
    
    /// Translate audio to English (any language → English)
    /// Note: whisper-large-v3-turbo doesn't support translate, must use whisper-large-v3
    static func translate(
        fileURL: URL,
        apiKey: String,
        model: String = "whisper-large-v3",
        prompt: String? = nil,
        completion: @escaping (String) -> Void
    ) {
        callWhisper(
            endpoint: "translations",
            fileURL: fileURL,
            apiKey: apiKey,
            model: "whisper-large-v3",  // force v3, turbo doesn't support translate
            language: nil,  // translations endpoint doesn't use language
            prompt: prompt,
            completion: completion
        )
    }
    
    // MARK: - Private
    
    private static func callWhisper(
        endpoint: String,
        fileURL: URL,
        apiKey: String,
        model: String,
        language: String?,
        prompt: String?,
        completion: @escaping (String) -> Void
    ) {
        guard let url = URL(string: "https://api.groq.com/openai/v1/audio/\(endpoint)") else {
            completion("")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        
        let boundary = "TypeFish-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        
        // model
        body.appendField(boundary: boundary, name: "model", value: model)
        
        // language (transcriptions only)
        if let lang = language, !lang.isEmpty {
            body.appendField(boundary: boundary, name: "language", value: lang)
        }
        
        // prompt
        if let prompt = prompt, !prompt.isEmpty {
            body.appendField(boundary: boundary, name: "prompt", value: prompt)
        }
        
        // file
        guard let fileData = try? Data(contentsOf: fileURL) else {
            Log.info("⚠️ Failed to read audio file: \(fileURL.path)")
            completion("")
            return
        }
        
        let ext = fileURL.pathExtension.lowercased()
        let mimeType = ext == "m4a" ? "audio/mp4" : "audio/wav"
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.\(ext)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        
        let startTime = CFAbsoluteTimeGetCurrent()
        let mode = endpoint == "translations" ? "🌐 Translate" : "🎯 Whisper"
        Log.info("\(mode): uploading \(fileData.count / 1024)KB...")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            
            if let error = error {
                Log.info("❌ \(mode) error: \(error.localizedDescription)")
                completion("")
                return
            }
            
            guard let data = data else {
                Log.info("❌ \(mode): no response")
                completion("")
                return
            }
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = json["text"] as? String {
                Log.info("✅ \(mode) (\(String(format: "%.1f", elapsed))s): \(text.prefix(100))...")
                completion(text)
            } else {
                let responseStr = String(data: data, encoding: .utf8) ?? "unknown"
                Log.info("❌ \(mode) bad response: \(responseStr.prefix(200))")
                completion("")
            }
        }.resume()
    }
}

// MARK: - Data helpers
extension Data {
    mutating func appendField(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }
}
