import AppKit

/// Adapts polisher tone based on the focused application.
/// Detects app type and returns appropriate tone modifiers for the polisher prompt.
enum AppToneAdapter {
    
    enum AppTone: String {
        case casual      // Slack, Discord, WhatsApp, iMessage, WeChat
        case professional // Gmail, Outlook, Mail
        case technical   // VS Code, Terminal, Xcode, IntelliJ
        case neutral     // Everything else (Docs, Notes, TextEdit)
    }
    
    /// Detect the tone for the currently saved frontmost app
    static func detectTone() -> AppTone {
        guard let app = PasteService.savedApp else { return .neutral }
        let bundleId = app.bundleIdentifier ?? ""
        let appName = app.localizedName ?? ""
        
        // Messaging apps → casual
        let casualBundles = [
            "com.tinyspeck.slackmacgap",   // Slack
            "com.hnc.Discord",              // Discord
            "net.whatsapp.WhatsApp",        // WhatsApp
            "com.apple.MobileSMS",          // iMessage
            "com.tencent.xinWeChat",        // WeChat
            "com.facebook.archon",          // Messenger
            "org.telegram.desktop",         // Telegram
            "com.microsoft.teams2",         // Teams (chat mode)
        ]
        if casualBundles.contains(bundleId) { return .casual }
        
        // Email apps → professional
        let professionalBundles = [
            "com.apple.mail",               // Apple Mail
            "com.microsoft.Outlook",        // Outlook
            "com.google.Chrome",            // Could be Gmail — check further
            "com.readdle.smartemail.macos",  // Spark
        ]
        if professionalBundles.contains(bundleId) {
            // For Chrome, we'd need to check the URL, but we don't have it here
            // Default to neutral for browsers
            if bundleId == "com.google.Chrome" { return .neutral }
            return .professional
        }
        
        // Code editors → technical
        let technicalBundles = [
            "com.microsoft.VSCode",         // VS Code
            "com.apple.Terminal",            // Terminal
            "com.apple.dt.Xcode",           // Xcode
            "com.jetbrains.intellij",       // IntelliJ
            "dev.warp.Warp-Stable",         // Warp
            "com.googlecode.iterm2",        // iTerm2
            "md.obsidian",                  // Obsidian (technical writing)
        ]
        if technicalBundles.contains(bundleId) { return .technical }
        
        // Name-based fallback
        let casualNames = ["Slack", "Discord", "WhatsApp", "WeChat", "Telegram", "Messages"]
        if casualNames.contains(appName) { return .casual }
        
        let technicalNames = ["Terminal", "Code", "Xcode", "iTerm"]
        if technicalNames.contains(where: { appName.contains($0) }) { return .technical }
        
        return .neutral
    }
    
    /// Get the polisher prompt modifier for the detected tone
    static func tonePromptModifier() -> String? {
        let tone = detectTone()
        
        switch tone {
        case .casual:
            return """
            TONE: The user is writing in a messaging/chat app. Keep the tone casual and conversational. \
            Use shorter sentences. Don't over-formalize. Contractions are fine. \
            Don't add excessive punctuation. Keep it how people actually text.
            """
        case .professional:
            return """
            TONE: The user is writing a professional email or document. Use proper punctuation and grammar. \
            Slightly more formal tone. Complete sentences. But don't be stiff — keep it natural-professional.
            """
        case .technical:
            return """
            TONE: The user is in a code editor or terminal. Preserve technical terms exactly as spoken. \
            Keep formatting minimal. Code-related terms should stay in English even in Chinese context.
            """
        case .neutral:
            return nil  // Use default polisher prompt as-is
        }
    }
}
