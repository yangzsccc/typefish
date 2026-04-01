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
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 280),
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
        titleLabel.frame = NSRect(x: 24, y: 228, width: 280, height: 32)
        content.addSubview(titleLabel)
        
        // Version
        let versionLabel = NSTextField(labelWithString: "v\(Updater.currentVersion)")
        versionLabel.font = NSFont.systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.frame = NSRect(x: 24, y: 210, width: 280, height: 18)
        content.addSubview(versionLabel)
        
        // Divider
        let divider1 = NSBox(frame: NSRect(x: 24, y: 200, width: 272, height: 1))
        divider1.boxType = .separator
        content.addSubview(divider1)
        
        // Status
        let statusTitle = NSTextField(labelWithString: "Status")
        statusTitle.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        statusTitle.textColor = .secondaryLabelColor
        statusTitle.frame = NSRect(x: 24, y: 176, width: 280, height: 16)
        content.addSubview(statusTitle)
        
        let sl = NSTextField(labelWithString: "● Ready")
        sl.font = NSFont.systemFont(ofSize: 14)
        sl.textColor = .systemGreen
        sl.frame = NSRect(x: 24, y: 155, width: 280, height: 20)
        content.addSubview(sl)
        self.statusLabel = sl
        
        // Divider
        let divider2 = NSBox(frame: NSRect(x: 24, y: 145, width: 272, height: 1))
        divider2.boxType = .separator
        content.addSubview(divider2)
        
        // Hotkeys
        let hotkeyTitle = NSTextField(labelWithString: "Shortcuts")
        hotkeyTitle.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        hotkeyTitle.textColor = .secondaryLabelColor
        hotkeyTitle.frame = NSRect(x: 24, y: 121, width: 280, height: 16)
        content.addSubview(hotkeyTitle)
        
        let hotkeys = [
            ("⌥ Space", "Toggle Recording"),
            ("⌃⌥ Space", "Translate to English"),
            ("Esc", "Cancel Recording")
        ]
        
        for (i, (key, desc)) in hotkeys.enumerated() {
            let y = 96 - i * 22
            
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
        let divider3 = NSBox(frame: NSRect(x: 24, y: 40, width: 272, height: 1))
        divider3.boxType = .separator
        content.addSubview(divider3)
        
        // Dictionary stats
        let dl = NSTextField(labelWithString: dictionaryStatsText())
        dl.font = NSFont.systemFont(ofSize: 11)
        dl.textColor = .secondaryLabelColor
        dl.frame = NSRect(x: 24, y: 16, width: 280, height: 18)
        content.addSubview(dl)
        self.dictLabel = dl
        
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
        
        dictLabel?.stringValue = dictionaryStatsText()
    }
    
    private func dictionaryStatsText() -> String {
        guard let state = state else { return "" }
        let d = state.dictionary
        return "📖 \(d.hints.count) hints · \(d.replacements.count) replacements · \(d.vocabulary.count) vocab"
    }
}
