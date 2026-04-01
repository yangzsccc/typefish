import Foundation

/// AI Voice Command processor.
/// Takes a voice instruction + optional selected text → generates AI content.
/// Uses Groq LLM (same key as polisher) for lightweight, fast generation.
enum AICommand {
    
    /// Process a voice command with optional context
    static func process(
        instruction: String,
        selectedText: String?,
        fieldContext: String?,
        apiKey: String,
        completion: @escaping (String?) -> Void
    ) {
        guard let url = URL(string: "https://api.groq.com/openai/v1/chat/completions") else {
            completion(nil)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        
        let systemPrompt: String
        let userMessage: String
        
        if let selected = selectedText, !selected.isEmpty {
            // Mode: Edit/transform selected text
            systemPrompt = """
            You are an AI writing assistant. The user has selected some text and given a voice command about what to do with it.
            
            Rules:
            - Output ONLY the result text. No explanations, no preamble, no "Here's the result:".
            - If the command is to rewrite/rephrase/shorten/expand, output the modified version of the selected text.
            - If the command is a question about the text (summarize, explain, translate), output the answer.
            - Match the language of the selected text unless the user asks for translation.
            - Keep formatting (line breaks, bullet points) if appropriate.
            """
            
            userMessage = """
            Selected text:
            \(selected)
            
            Voice command: \(instruction)
            """
        } else {
            // Mode: Generate new content from scratch
            systemPrompt = """
            You are an AI writing assistant activated by voice command. The user spoke a command describing what they want written.
            
            Rules:
            - Output ONLY the generated content. No explanations, no "Sure, here's..." preamble.
            - Infer the format from the command (email, message, list, code, etc.).
            - For emails: include greeting and sign-off. Use "Best," or similar casual-professional closing.
            - For messages: keep it natural and conversational.
            - Match the language of the user's command unless they ask for a specific language.
            - Be concise but complete.
            """
            
            var contextNote = ""
            if let ctx = fieldContext, !ctx.isEmpty {
                contextNote = "\n\nContext (text already in the field before cursor):\n\(ctx)"
            }
            
            userMessage = "Voice command: \(instruction)\(contextNote)"
        }
        
        let payload: [String: Any] = [
            "model": "llama-3.3-70b-versatile",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage]
            ],
            "temperature": 0.7,
            "max_tokens": 2000
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            completion(nil)
            return
        }
        request.httpBody = jsonData
        
        Log.info("🤖 AI Command: instruction=[\(instruction.prefix(80))] selected=[\(selectedText?.prefix(40) ?? "none")]")
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            
            if let error = error {
                Log.info("🤖 AI Command error: \(error.localizedDescription)")
                completion(nil)
                return
            }
            
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                Log.info("🤖 AI Command: bad response")
                completion(nil)
                return
            }
            
            let result = content.trimmingCharacters(in: .whitespacesAndNewlines)
            Log.info("🤖 AI Command done (\(String(format: "%.1f", elapsed))s): \(result.prefix(100))...")
            completion(result.isEmpty ? nil : result)
        }.resume()
    }
}
