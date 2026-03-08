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
    /// Only strip these when they appear as TRAILING lines after real content
    private static let garbagePatterns: [String] = [
        "Note:", "注：", "注意：", "备注：",
        "Here is", "Here's", "以上是", "以下是",
        "I hope", "希望", "如果你",
        "Output:", "Result:", "Cleaned:",
        "---", "***",
        "(Note", "（注",
    ]
    
    /// Known Whisper hallucinations — if the ENTIRE output matches, treat as empty
    private static let whisperHallucinations: [String] = [
        "Feel free to let me know",
        "Thank you for watching",
        "Thanks for watching",
        "Please subscribe",
        "Subtitles by",
        "字幕由",
        "谢谢观看",
        "感谢收看",
        "请订阅",
        "ご視聴ありがとうございました",
        "MBC 뉴스",
        "www.mooji.org",
        "Amara.org",
    ]
    
    /// Check if text is a known Whisper hallucination
    static func isHallucination(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
            .trimmingCharacters(in: .whitespaces)
        return whisperHallucinations.contains { trimmed.hasPrefix($0) }
    }
    
    /// Remove trailing lines that look like LLM commentary.
    /// Never produces empty output — returns original if stripping would empty it.
    static func stripTrailingGarbage(_ text: String, originalLineCount: Int) -> String {
        var lines = text.components(separatedBy: "\n")
        
        // Remove trailing empty lines first
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }
        
        // Check last 1-2 lines for garbage patterns
        var stripped = false
        for _ in 0..<2 {
            guard lines.count > 1 else { break }  // Never strip the last remaining line
            guard let lastLine = lines.last?.trimmingCharacters(in: .whitespaces) else { break }
            let isGarbage = garbagePatterns.contains { lastLine.hasPrefix($0) }
            if isGarbage {
                Log.info("🧹 Stripped trailing garbage: \(lastLine.prefix(50))")
                lines.removeLast()
                stripped = true
            }
        }
        
        if stripped {
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true && lines.count > 1 {
                lines.removeLast()
            }
        }
        
        let result = lines.joined(separator: "\n")
        // Safety: never return empty
        return result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : result
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
        Output: 帮我写一个Python脚本来做数据分析。
        
        Input: <transcription>what is the time complexity of binary search I think it's log n right</transcription>
        Output: What is the time complexity of binary search? I think it's log n, right?
        
        Input: <transcription>我昨天去了那个什么来着 不对 是前天去了costco买了一些东西</transcription>
        Output: 我前天去了Costco买了一些东西。
        
        Input: <transcription>this should use a hash map no wait actually a tree map would be better for this case</transcription>
        Output: This should use a tree map, that would be better for this case.
        
        Input: <transcription>把FaceSwamp这个Channel的名字改一下这是一个比较敏感的任务这个名字感觉会reveal一些信息你改成一些很不引人注目的很普通的名字</transcription>
        Output: 把FaceSwamp这个Channel的名字改一下，这是一个比较敏感的任务。这个名字感觉会reveal一些信息，你改成一些很不引人注目的，很普通的名字。
        
        Input: <transcription>你来帮我跑吧你分析一下我给的这些照片哪一些照片是比较好的candidate选5到10张然后我告诉你具体选哪张</transcription>
        Output: 你来帮我跑吧，你分析一下我给的这些照片，哪一些照片是比较好的candidate，选5到10张，然后我告诉你具体选哪张。
        
        Input: <transcription>前十秒没有什么人物的正点你去用从第15秒到第32秒之间做测试</transcription>
        Output: 前十秒没有什么人物的正点，你去用从第15秒到第32秒之间做测试。
        
        Input: <transcription>我感觉现在如果我语速比较快的话它好像就不怎么加标点符号你的标点符号是按照我的停顿时间来的还是按照语义来的我就在语义方面的加标点符号和reformatting这些可以再加强一些</transcription>
        Output: 我感觉现在如果我语速比较快的话，它好像就不怎么加标点符号。你的标点符号是按照我的停顿时间来的，还是按照语义来的？我觉得在语义方面的加标点符号和reformatting这些可以再加强一些。
        
        Input: <transcription>你有提到SecretKey永远不在API请求中传输那当在onboarding的时候我们生成了这个Key是怎么样让merchant拿到的</transcription>
        Output: 你有提到SecretKey永远不在API请求中传输，那当在onboarding的时候，我们生成了这个Key是怎么样让merchant拿到的？
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
                
                // Layer 3a: Length guard — if output is >1.5x longer, LLM probably added content
                let ratio = Double(polished.count) / Double(trimmed.count)
                if ratio > 1.5 {
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
