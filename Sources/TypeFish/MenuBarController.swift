import AppKit

/// Manages the menu bar status item (icon + menu).
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
    
    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
