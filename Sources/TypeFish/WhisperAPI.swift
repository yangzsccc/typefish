import Foundation

/// Transcribes audio files using Groq's Whisper API.
enum WhisperAPI {
    
    /// Transcribe an audio file using Groq Whisper
    /// - Parameters:
    ///   - fileURL: Path to the audio file (WAV, M4A, etc.)
    ///   - apiKey: Groq API key
    ///   - model: Whisper model name
    ///   - completion: Called with the transcribed text (empty string on failure)
    static func transcribe(
        fileURL: URL,
        apiKey: String,
        model: String = "whisper-large-v3-turbo",
        language: String? = nil,
        prompt: String? = nil,
        completion: @escaping (String) -> Void
    ) {
        guard let url = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions") else {
            completion("")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        
        let boundary = "TypeFish-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        // Build multipart body
        var body = Data()
        
        // model field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(model)\r\n".data(using: .utf8)!)
        
        // language field (helps accuracy for zh/en)
        if let lang = language, !lang.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(lang)\r\n".data(using: .utf8)!)
        }
        
        // language field
        if let lang = language, !lang.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(lang)\r\n".data(using: .utf8)!)
        }
        
        // prompt field (vocabulary hints for better recognition)
        if let prompt = prompt, !prompt.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(prompt)\r\n".data(using: .utf8)!)
        }
        
        // file field
        guard let fileData = try? Data(contentsOf: fileURL) else {
            Log.info("⚠️ Failed to read audio file: \(fileURL.path)")
            completion("")
            return
        }
        
        let ext = fileURL.pathExtension.lowercased()
        let mimeType = ext == "m4a" ? "audio/mp4" : "audio/wav"
        let filename = "audio.\(ext)"
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        
        let startTime = CFAbsoluteTimeGetCurrent()
        Log.info("🎯 Whisper: uploading \(fileData.count / 1024)KB...")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            
            if let error = error {
                Log.info("❌ Whisper error: \(error.localizedDescription)")
                completion("")
                return
            }
            
            guard let data = data else {
                Log.info("❌ Whisper: no response")
                completion("")
                return
            }
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = json["text"] as? String {
                Log.info("✅ Whisper (\(String(format: "%.1f", elapsed))s): \(text.prefix(100))...")
                completion(text)
            } else {
                let responseStr = String(data: data, encoding: .utf8) ?? "unknown"
                Log.info("❌ Whisper bad response: \(responseStr.prefix(200))")
                completion("")
            }
        }.resume()
    }
}
