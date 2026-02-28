import AppKit

/// Manages the menu bar status item (icon + menu).
/// NSTextField subclass that supports Cmd+V paste, Cmd+A select all, etc.
class EditableTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command {
            switch event.charactersIgnoringModifiers {
            case "v":
                NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
                return true
            case "c":
                NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
                return true
            case "x":
                NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
                return true
            case "a":
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

class MenuBarController {
    
    private var statusItem: NSStatusItem!
    private let state: AppState
    
    init(state: AppState) {
        self.state = state
        setupStatusItem()
        
        // Listen for state changes
        state.onStateChange = { [weak self] in
            self?.updateIcon()
        }
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        updateIcon()
        
        // Create menu
        let menu = NSMenu()
        
        let statusMenuItem = NSMenuItem(title: "TypeFish 🐟", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let hotkeyItem = NSMenuItem(title: "⌥ Space — Toggle Recording", action: nil, keyEquivalent: "")
        hotkeyItem.isEnabled = false
        menu.addItem(hotkeyItem)
        
        let escItem = NSMenuItem(title: "⎋ Esc — Cancel Recording", action: nil, keyEquivalent: "")
        escItem.isEnabled = false
        menu.addItem(escItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Dictionary section
        let dictHeader = NSMenuItem(title: "📖 Dictionary", action: nil, keyEquivalent: "")
        dictHeader.isEnabled = false
        menu.addItem(dictHeader)
        
        let addWordItem = NSMenuItem(title: "Add Word...", action: #selector(addWord), keyEquivalent: "d")
        addWordItem.target = self
        menu.addItem(addWordItem)
        
        let addCorrectionItem = NSMenuItem(title: "Add Correction...", action: #selector(addCorrection), keyEquivalent: "")
        addCorrectionItem.target = self
        menu.addItem(addCorrectionItem)
        
        let editDictItem = NSMenuItem(title: "Edit Dictionary File", action: #selector(editDictionary), keyEquivalent: "")
        editDictItem.target = self
        menu.addItem(editDictItem)
        
        let reloadDictItem = NSMenuItem(title: "Reload Dictionary", action: #selector(reloadDictionary), keyEquivalent: "")
        reloadDictItem.target = self
        menu.addItem(reloadDictItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit TypeFish", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem.menu = menu
    }
    
    func updateIcon() {
        guard let button = statusItem.button else { return }
        
        if state.isRecording {
            // Red circle when recording
            button.image = createIcon(recording: true)
            button.toolTip = "TypeFish — Recording..."
        } else if state.isProcessing {
            // Processing indicator
            button.image = createIcon(processing: true)
            button.toolTip = "TypeFish — Processing..."
        } else {
            // Normal mic icon
            button.image = createIcon()
            button.toolTip = "TypeFish — ⌥Space to dictate"
        }
    }
    
    /// Create a simple menu bar icon
    private func createIcon(recording: Bool = false, processing: Bool = false) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            if recording {
                // Red filled circle
                NSColor.systemRed.setFill()
                let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3))
                circle.fill()
            } else if processing {
                // Orange circle outline
                NSColor.systemOrange.setStroke()
                let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4))
                circle.lineWidth = 2
                circle.stroke()
            } else {
                // Fish emoji-style: simple mic shape
                NSColor.labelColor.setFill()
                // Mic body (rounded rect)
                let body = NSBezierPath(roundedRect: NSRect(x: 6, y: 6, width: 6, height: 9), xRadius: 3, yRadius: 3)
                body.fill()
                // Mic stand
                NSColor.labelColor.setStroke()
                let stand = NSBezierPath()
                stand.move(to: NSPoint(x: 9, y: 3))
                stand.line(to: NSPoint(x: 9, y: 6))
                stand.lineWidth = 1.5
                stand.stroke()
                // Base
                let base = NSBezierPath()
                base.move(to: NSPoint(x: 6, y: 3))
                base.line(to: NSPoint(x: 12, y: 3))
                base.lineWidth = 1.5
                base.stroke()
            }
            return true
        }
        image.isTemplate = !recording && !processing  // Template for dark/light mode (normal state only)
        return image
    }
    
    // MARK: - Dictionary Actions
    
    @objc private func addWord() {
        let alert = NSAlert()
        alert.messageText = "Add Word (Whisper Hint)"
        alert.informativeText = "Add words Whisper often gets wrong.\nOnly for unusual/tricky words — common words don't need this.\nComma-separated for multiple."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        
        let input = EditableTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.placeholderString = "e.g. Junyan, pgvector, Chipotle"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let words = input.stringValue
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            
            for word in words {
                state.dictionary.addHint(word)
            }
            
            if !words.isEmpty {
                showNotification("📖 Added \(words.count) hint(s): \(words.joined(separator: ", "))")
            }
        }
    }
    
    @objc private func addCorrection() {
        let alert = NSAlert()
        alert.messageText = "Add Correction"
        alert.informativeText = "When Whisper outputs the wrong word, replace it.\nExample: 俊言 → Junyan"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 58))
        
        let wrongLabel = NSTextField(labelWithString: "Wrong:")
        wrongLabel.frame = NSRect(x: 0, y: 34, width: 50, height: 20)
        container.addSubview(wrongLabel)
        
        let wrongInput = EditableTextField(frame: NSRect(x: 55, y: 32, width: 245, height: 24))
        wrongInput.placeholderString = "What Whisper outputs"
        container.addSubview(wrongInput)
        
        let rightLabel = NSTextField(labelWithString: "Right:")
        rightLabel.frame = NSRect(x: 0, y: 4, width: 50, height: 20)
        container.addSubview(rightLabel)
        
        let rightInput = EditableTextField(frame: NSRect(x: 55, y: 2, width: 245, height: 24))
        rightInput.placeholderString = "What it should be"
        container.addSubview(rightInput)
        
        alert.accessoryView = container
        alert.window.initialFirstResponder = wrongInput
        
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let wrong = wrongInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let right = rightInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if !wrong.isEmpty && !right.isEmpty {
                state.dictionary.addReplacement(wrong: wrong, right: right)
                showNotification("📖 Added: \(wrong) → \(right)")
            }
        }
    }
    
    @objc private func editDictionary() {
        // Open dictionary file in default editor
        NSWorkspace.shared.open(CustomDictionary.fileURL)
    }
    
    @objc private func reloadDictionary() {
        state.dictionary = CustomDictionary.load()
        showNotification("📖 Dictionary reloaded: \(state.dictionary.vocabulary.count) vocab, \(state.dictionary.replacements.count) replacements")
    }
    
    private func showNotification(_ message: String) {
        Log.info(message)
        // Brief tooltip update
        if let button = statusItem.button {
            let prev = button.toolTip
            button.toolTip = message
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                button.toolTip = prev
            }
        }
    }
    
    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
