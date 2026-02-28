import Foundation

/// Light text polish using Groq LLM.
/// Fixes stutters, repetitions, self-corrections. Keeps original wording.
///
/// Multi-layer defense against LLM answering questions:
/// 1. XML tags: wrap input as <transcription> data, not instruction
/// 2. Few-shot examples: show question inputs returned as-is
/// 3. Length guard: if output is much longer than input, discard it
enum TextPolisher {
    
    /// Common patterns LLMs add that aren't part of the transcription
    private static let garbagePatterns: [String] = [
        "Note:", "注：", "注意：", "备注：",
        "Here is", "Here's", "以上是", "以下是",
        "I hope", "希望", "如果你",
        "Let me know", "Feel free",
        "Output:", "Result:", "Cleaned:",
        "---", "***",
        "(Note", "（注",
    ]
    
    /// Remove trailing lines that look like LLM commentary
    static func stripTrailingGarbage(_ text: String, originalLineCount: Int) -> String {
        var lines = text.components(separatedBy: "\n")
        
        // Remove trailing empty lines first
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }
        
        // Check last 1-2 lines for garbage patterns
        var stripped = false
        for _ in 0..<2 {
            guard let lastLine = lines.last?.trimmingCharacters(in: .whitespaces) else { break }
            let isGarbage = garbagePatterns.contains { lastLine.hasPrefix($0) }
            if isGarbage {
                Log.info("🧹 Stripped trailing garbage: \(lastLine.prefix(50))")
                lines.removeLast()
                stripped = true
            }
        }
        
        if stripped {
            // Trim trailing empty lines again
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                lines.removeLast()
            }
        }
        
        return lines.joined(separator: "\n")
    }
    
    /// Polish raw transcript text
    static func polish(
        text: String,
        apiKey: String,
        model: String = "llama-3.3-70b-versatile",
        systemPrompt: String,
        completion: @escaping (String) -> Void
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion("")
            return
        }
        
        // Only skip very short text (< 5 characters)
        if trimmed.count < 5 {
            Log.info("✨ Text too short for polish (\(trimmed.count) chars), returning as-is")
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
        
        // Layer 1: Wrap input in XML tags to mark it as DATA, not instruction
        let userMessage = """
        <transcription>
        \(trimmed)
        </transcription>
        
        Clean up the transcription above. Output ONLY the cleaned text.
        """
        
        // Layer 2: Few-shot examples showing questions returned as-is
        let fewShotSystemPrompt = systemPrompt + """
        
        
        Examples:
        
        Input: <transcription>帮我写一个Python脚本来做数据分析</transcription>
        Output: 帮我写一个 Python 脚本来做数据分析。
        
        Input: <transcription>嗯那个根据这个里面的面筋给我制定一个准备Vemo面试DSA的训练计划</transcription>
        Output: 根据这个里面的面经，给我制定一个准备 Vemo 面试 DSA 的训练计划。
        
        Input: <transcription>what is the time complexity of binary search I think it's log n right</transcription>
        Output: What is the time complexity of binary search? I think it's log n, right?
        """
        
        // Cap max_tokens to prevent long generation
        // Polish should never produce much more than the input
        let maxTokens = max(trimmed.count, 200)
        
        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": fewShotSystemPrompt],
                ["role": "user", "content": userMessage]
            ],
            "temperature": 0.1,
            "max_tokens": maxTokens
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
                completion(trimmed)
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
                var polished = content.trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Strip XML tags if the model echoed them back
                polished = polished
                    .replacingOccurrences(of: "<transcription>", with: "")
                    .replacingOccurrences(of: "</transcription>", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Layer 3a: Length guard — if output is >1.3x longer, LLM probably added content
                let ratio = Double(polished.count) / Double(trimmed.count)
                if ratio > 1.3 {
                    Log.info("⚠️ Polish output too long (\(polished.count) vs \(trimmed.count) chars, ratio \(String(format: "%.1f", ratio))x) — using raw transcription.")
                    completion(trimmed)
                    return
                }
                
                // Layer 3b: Strip trailing LLM commentary lines
                polished = TextPolisher.stripTrailingGarbage(polished, originalLineCount: trimmed.components(separatedBy: "\n").count)
                
                Log.info("✅ Polished (\(String(format: "%.1f", elapsed))s): \(polished.prefix(100))...")
                completion(polished)
            } else {
                let responseStr = String(data: data, encoding: .utf8) ?? "unknown"
                Log.info("⚠️ Polish bad response: \(responseStr.prefix(200))")
                completion(trimmed)
            }
        }.resume()
    }
}
