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
    
    /// Fallback model when primary hits rate limit
    /// Note: 8b-instant had severe issues with adding commentary like "(no phonetic error found)"
    /// Note: 70b-specdec was decommissioned by Groq
    /// Using same 70b model with retry — better to wait than use 8b
    private static let fallbackModel = "llama-3.3-70b-versatile"
    
    /// Polish raw transcript text
    static func polish(
        text: String,
        apiKey: String,
        model: String = "llama-3.3-70b-versatile",
        systemPrompt: String,
        isFallback: Bool = false,
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
        
        Clean up the transcription above. Output ONLY the cleaned text, nothing else. Do not add any notes, comments, or annotations in parentheses.
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
        
        Input: <transcription>hi Eric that sounds great I have submitted the application and looking forward to the next step best Shuchen</transcription>
        Output: Hi Eric,

        That sounds great. I have submitted the application and looking forward to the next step.

        Best,
        Shuchen

        Input: <transcription>帮我draft一个给Airbnb内推人的中文的信息包含我要投的岗位对应的简历然后第三人称自我介绍这会是一个微信的message这个人我关系还算比较熟不是陌生人</transcription>
        Output: 帮我draft一个给Airbnb内推人的中文信息，包含：
        1. 我要投的岗位
        2. 对应的简历
        3. 第三人称自我介绍

        这会是一个微信的message，这个人我关系还算比较熟，不是陌生人。

        Input: <transcription>我不知道你是怎么判断简历的版本的但是我觉得像这个岗位明显是与AI Infra相关的你为什么选择用Data Infra的那个basic template而没有用我的ML Ops的那个template呢我觉得那个更合适</transcription>
        Output: 我不知道你是怎么判断简历版本的，但是我觉得像这个岗位明显是与AI Infra相关的。

        你为什么选择用Data Infra的那个basic template，而没有用我的ML Ops的那个template呢？我觉得那个更合适。

        Input: <transcription>我们首先需要知道对于senior candidate更容易被问到哪些方面的behavior question并且保证我们准备好的story无论是从stakeholder还是impact都必须得是senior plus level</transcription>
        Output: 我们首先需要知道对于senior candidate更容易被问到哪些方面的behavior question，并且保证我们准备好的story，无论是从stakeholder还是impact角度，都必须得是senior plus level。

        Input: <transcription>这个是我直接得到的面试的feedback和自己的感悟但我不知道怎么样能够通过这些感悟convert成一个更好的behavior question preparation doc</transcription>
        Output: 这个是我直接得到的面试的feedback和自己的感悟，但我不知道怎么样能够通过这些感悟convert成一个更好的behavior question preparation doc。
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
            
            // Check for rate limit (429) — retry after delay (same model)
            // Previously fell back to 8b which caused "(no phonetic error found)" contamination
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 429 {
                if !isFallback {
                    Log.info("⚠️ Rate limited on \(model), retrying in 3s with same model")
                    DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) {
                        polish(text: text, apiKey: apiKey, model: model, systemPrompt: systemPrompt, isFallback: true, completion: completion)
                    }
                } else {
                    // Already retried once, just return raw text
                    Log.info("⚠️ Rate limited twice, returning raw transcription")
                    completion(trimmed)
                }
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
                
                // Strip LLM inline commentary that leaks into output
                // Phase 1: Direct string replacements (most reliable)
                let directGarbage = [
                    "(no phonetic error found)",
                    "(No phonetic error found)",
                    "(no phonetic errors found)",
                    "(No phonetic errors found)",
                    "(no speech error found)",
                    "(no speech errors found)",
                    "(no STT error found)",
                    "(no errors found)",
                    "(no changes needed)",
                    "(no changes made)",
                    "(no change needed)",
                    "(unchanged)",
                    "(Unchanged)",
                    "No phonetic error found",
                    "No phonetic errors found",
                    "NoPhoneticErrorFound",
                    "NoFuneticEraFound",
                    "(no correction needed)",
                    "(no corrections needed)",
                    "(no correction found)",
                    "(no corrections found)",
                ]
                for garbage in directGarbage {
                    if polished.contains(garbage) {
                        Log.info("🧹 Stripped LLM commentary: \(garbage)")
                        polished = polished.replacingOccurrences(of: garbage, with: "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                
                // Phase 2: Regex for patterns we can't enumerate
                let inlineGarbagePatterns = [
                    "\\(no \\w+ (?:error|change|correction)s? found\\)",
                    "\\(Note:.*?\\)",
                    "\\(注[：:].*?\\)",
                    "\\[no (?:error|change|correction)s? found\\]",
                ]
                for pattern in inlineGarbagePatterns {
                    if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                        let range = NSRange(polished.startIndex..., in: polished)
                        let cleaned = regex.stringByReplacingMatches(in: polished, range: range, withTemplate: " ")
                            .replacingOccurrences(of: "  ", with: " ")
                        let trimCleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimCleaned != polished.trimmingCharacters(in: .whitespacesAndNewlines) && !trimCleaned.isEmpty {
                            Log.info("🧹 Stripped inline LLM commentary matching: \(pattern)")
                            polished = trimCleaned
                        }
                    }
                }
                
                // Layer 3a: Length guard — if output is >1.8x longer, LLM probably added content
                // (1.8x instead of 1.5x to allow email formatting with line breaks)
                let ratio = Double(polished.count) / Double(trimmed.count)
                if ratio > 1.8 {
                    Log.info("⚠️ Polish output too long (\(polished.count) vs \(trimmed.count) chars, ratio \(String(format: "%.1f", ratio))x) — using raw transcription.")
                    completion(trimmed)
                    return
                }
                
                // Layer 3b: Strip trailing LLM commentary lines
                polished = TextPolisher.stripTrailingGarbage(polished, originalLineCount: trimmed.components(separatedBy: "\n").count)
                
                let modelTag = isFallback ? " [fallback:\(model)]" : ""
                Log.info("✅ Polished (\(String(format: "%.1f", elapsed))s)\(modelTag): \(polished.prefix(100))...")
                completion(polished)
            } else {
                let responseStr = String(data: data, encoding: .utf8) ?? "unknown"
                Log.info("⚠️ Polish bad response: \(responseStr.prefix(200))")
                completion(trimmed)
            }
        }.resume()
    }
}
