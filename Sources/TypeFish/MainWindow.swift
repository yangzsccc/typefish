import AppKit

/// Simple main window shown when clicking Dock icon.
/// Displays status, version, hotkeys, and dictionary stats.
class MainWindow {
    
    private var window: NSWindow?
    private weak var state: AppState?
    
    // UI elements that update
    private var statusLabel: NSTextField?
    private var dictLabel: NSTextField?
    
    init(state: AppState) {
        self.state = state
    }
    
    func showWindow() {
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 320),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.title = "TypeFish"
        w.center()
        w.isReleasedWhenClosed = false
        w.titlebarAppearsTransparent = true
        w.backgroundColor = NSColor.windowBackgroundColor
        
        let content = NSView(frame: w.contentView!.bounds)
        content.autoresizingMask = [.width, .height]
        
        // Fish emoji + title
        let titleLabel = NSTextField(labelWithString: "🐟 TypeFish")
        titleLabel.font = NSFont.systemFont(ofSize: 24, weight: .bold)
        titleLabel.frame = NSRect(x: 24, y: 248, width: 280, height: 32)
        content.addSubview(titleLabel)
        
        // Version
        let versionLabel = NSTextField(labelWithString: "v\(Updater.currentVersion)")
        versionLabel.font = NSFont.systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.frame = NSRect(x: 24, y: 230, width: 280, height: 18)
        content.addSubview(versionLabel)
        
        // Divider
        let divider1 = NSBox(frame: NSRect(x: 24, y: 220, width: 272, height: 1))
        divider1.boxType = .separator
        content.addSubview(divider1)
        
        // Status
        let statusTitle = NSTextField(labelWithString: "Status")
        statusTitle.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        statusTitle.textColor = .secondaryLabelColor
        statusTitle.frame = NSRect(x: 24, y: 196, width: 280, height: 16)
        content.addSubview(statusTitle)
        
        let sl = NSTextField(labelWithString: "● Ready")
        sl.font = NSFont.systemFont(ofSize: 14)
        sl.textColor = .systemGreen
        sl.frame = NSRect(x: 24, y: 175, width: 280, height: 20)
        content.addSubview(sl)
        self.statusLabel = sl
        
        // Divider
        let divider2 = NSBox(frame: NSRect(x: 24, y: 165, width: 272, height: 1))
        divider2.boxType = .separator
        content.addSubview(divider2)
        
        // Hotkeys
        let hotkeyTitle = NSTextField(labelWithString: "Shortcuts")
        hotkeyTitle.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        hotkeyTitle.textColor = .secondaryLabelColor
        hotkeyTitle.frame = NSRect(x: 24, y: 141, width: 280, height: 16)
        content.addSubview(hotkeyTitle)
        
        let hotkeys = [
            ("⌥ Space", "Toggle Recording"),
            ("⌃⌥ Space", "Translate to English"),
            ("⌃⌥⌘ Space", "AI Command"),
            ("Esc", "Cancel Recording")
        ]
        
        for (i, (key, desc)) in hotkeys.enumerated() {
            let y = 116 - i * 22
            
            let keyLabel = NSTextField(labelWithString: key)
            keyLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            keyLabel.textColor = .labelColor
            keyLabel.frame = NSRect(x: 24, y: y, width: 90, height: 18)
            content.addSubview(keyLabel)
            
            let descLabel = NSTextField(labelWithString: desc)
            descLabel.font = NSFont.systemFont(ofSize: 12)
            descLabel.textColor = .secondaryLabelColor
            descLabel.frame = NSRect(x: 120, y: y, width: 180, height: 18)
            content.addSubview(descLabel)
        }
        
        // Divider
        let divider3 = NSBox(frame: NSRect(x: 24, y: 56, width: 272, height: 1))
        divider3.boxType = .separator
        content.addSubview(divider3)
        
        // Health stats
        let healthTitle = NSTextField(labelWithString: "Health (24h)")
        healthTitle.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        healthTitle.textColor = .secondaryLabelColor
        healthTitle.frame = NSRect(x: 24, y: 36, width: 280, height: 16)
        content.addSubview(healthTitle)
        
        let hl = NSTextField(labelWithString: healthStatsText())
        hl.font = NSFont.systemFont(ofSize: 11)
        hl.textColor = .secondaryLabelColor
        hl.frame = NSRect(x: 24, y: 16, width: 280, height: 18)
        content.addSubview(hl)
        self.dictLabel = hl
        
        w.contentView = content
        self.window = w
        
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        updateStatus()
    }
    
    func updateStatus() {
        guard let state = state else { return }
        
        if state.isRecording {
            statusLabel?.stringValue = state.isTranslateMode ? "● Translating..." : "● Recording..."
            statusLabel?.textColor = state.isTranslateMode ? .systemGreen : .systemRed
        } else if state.isProcessing {
            statusLabel?.stringValue = "● Processing..."
            statusLabel?.textColor = .systemOrange
        } else {
            statusLabel?.stringValue = "● Ready"
            statusLabel?.textColor = .systemGreen
        }
        
        dictLabel?.stringValue = healthStatsText()
    }
    
    private func healthStatsText() -> String {
        let stats = MetricsLogger.recentStats(hours: 24)
        if stats.total == 0 { return "No transcriptions yet" }
        let rate = stats.total > 0 ? Int(Double(stats.success) / Double(stats.total) * 100) : 0
        let styleProgress = StyleLearner.shared.progressPercent
        var text = "✅ \(stats.success)/\(stats.total) (\(rate)%) · 🧠 \(styleProgress)%"
        if !stats.errors.isEmpty {
            let errStr = stats.errors.map { "\($0.key):\($0.value)" }.joined(separator: " ")
            text += " · ❌ \(errStr)"
        }
        if stats.avgWhisperMs > 0 {
            text += " · ⏱ \(stats.avgWhisperMs)ms"
        }
        return text
    }
}
