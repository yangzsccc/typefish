import AppKit

/// Pastes text at the current cursor position.
/// Writes to pasteboard, then simulates Cmd+V.
enum PasteService {
    
    /// Paste text at current cursor position
    /// - Parameter text: The text to paste
    static func paste(_ text: String) {
        guard !text.isEmpty else { return }
        
        // Save current pasteboard content to restore later
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)
        
        // Write our text to pasteboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        
        // Small delay to ensure pasteboard is ready
        usleep(50_000)  // 50ms
        
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
