import Foundation

/// Light text polish using Groq LLM.
/// Fixes stutters, repetitions, self-corrections. Keeps original wording.
enum TextPolisher {
    
    /// Polish raw transcript text
    /// - Parameters:
    ///   - text: Raw transcript from Whisper
    ///   - apiKey: Groq API key
    ///   - model: LLM model name
    ///   - systemPrompt: System prompt for the polisher
    ///   - completion: Called with the polished text
    static func polish(
        text: String,
        apiKey: String,
        model: String = "llama-3.3-70b-versatile",
        systemPrompt: String,
        completion: @escaping (String) -> Void
    ) {
        // If text is very short or already clean, skip LLM
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion("")
            return
        }
        
        // For very short text (< 10 words), just return as-is
        if trimmed.split(separator: " ").count < 5 {
            Log.info("✨ Text too short for polish, returning as-is")
            completion(trimmed)
            return
        }
        
        guard let url = URL(string: "https://api.groq.com/openai/v1/chat/completions") else {
            completion(trimmed)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        
        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": trimmed]
            ],
            "temperature": 0.1,  // Low temp for minimal changes
            "max_tokens": 2048
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            completion(trimmed)
            return
        }
        
        request.httpBody = jsonData
        
        let startTime = CFAbsoluteTimeGetCurrent()
        Log.info("✨ Polishing \(trimmed.count) chars...")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            
            if let error = error {
                Log.info("⚠️ Polish error: \(error.localizedDescription)")
                completion(trimmed)  // Return unpolished on error
                return
            }
            
            guard let data = data else {
                completion(trimmed)
                return
            }
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let first = choices.first,
               let message = first["message"] as? [String: Any],
               let content = message["content"] as? String {
                let polished = content.trimmingCharacters(in: .whitespacesAndNewlines)
                Log.info("✅ Polished (\(String(format: "%.1f", elapsed))s): \(polished.prefix(100))...")
                completion(polished)
            } else {
                let responseStr = String(data: data, encoding: .utf8) ?? "unknown"
                Log.info("⚠️ Polish bad response: \(responseStr.prefix(200))")
                completion(trimmed)  // Return unpolished on error
            }
        }.resume()
    }
}
