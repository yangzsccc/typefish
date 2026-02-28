import AppKit

/// Pastes text at the current cursor position.
/// Tracks the frontmost app and restores focus before pasting.
enum PasteService {
    
    /// The app that was active when recording started
    private(set) static var savedApp: NSRunningApplication?
    
    /// Save reference to the currently focused app (call when recording starts)
    static func saveFrontmostApp() {
        savedApp = NSWorkspace.shared.frontmostApplication
        if let app = savedApp {
            Log.info("📌 Saved frontmost app: \(app.localizedName ?? "unknown") (pid: \(app.processIdentifier))")
        }
    }
    
    /// Paste text at current cursor position in the saved app
    /// - Parameter text: The text to paste
    static func paste(_ text: String) {
        guard !text.isEmpty else { return }
        
        // Save current pasteboard content to restore later
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)
        
        // Write our text to pasteboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        
        // Activate the saved app (the one user was typing in)
        if let app = savedApp {
            app.activate()
            Log.info("📌 Activated: \(app.localizedName ?? "unknown")")
            // Wait for app to come to front
            usleep(150_000)  // 150ms
        } else {
            usleep(50_000)  // 50ms
        }
        
        // Simulate Cmd+V
        simulatePaste()
        
        // Restore previous pasteboard content after a delay
        if let previous = previousContents {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }
        
        Log.info("📋 Pasted \(text.count) chars to cursor")
    }
    
    /// Simulate Cmd+V keypress
    private static func simulatePaste() {
        // Key code 9 = 'V'
        let source = CGEventSource(stateID: .hidSystemState)
        
        // Cmd+V down
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true) {
            keyDown.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
        }
        
        // Small delay between down and up
        usleep(10_000)  // 10ms
        
        // Cmd+V up
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) {
            keyUp.flags = .maskCommand
            keyUp.post(tap: .cghidEventTap)
        }
    }
}
