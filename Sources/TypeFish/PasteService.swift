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
    
    /// Paste text at current cursor position in the saved app.
    /// Returns true if paste was likely successful (a text field was focused).
    @discardableResult
    static func paste(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        
        // Check if there's a focused text input BEFORE pasting
        let hasTextInput = checkForTextInput()
        
        // Save current pasteboard content to restore later
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)
        
        // Write our text to pasteboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        
        if hasTextInput {
            // Activate the saved app (the one user was typing in)
            if let app = savedApp {
                app.activate()
                Log.info("📌 Activated: \(app.localizedName ?? "unknown")")
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
            return true
        } else {
            // No text input found — text stays on clipboard
            Log.info("📋 No text input focused — copied \(text.count) chars to clipboard")
            return false
        }
    }
    
    /// Check if there's likely a place to paste.
    /// We can't reliably detect text inputs (Electron apps like Discord don't support AX).
    /// Instead: if there's a frontmost app with a window, assume paste will work.
    /// Only return false when clearly on desktop / no app / no windows.
    private static func checkForTextInput() -> Bool {
        guard let app = savedApp else { return false }
        
        // Finder with no windows = desktop, nowhere to paste
        if app.bundleIdentifier == "com.apple.finder" {
            // Check if Finder has any regular windows open
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            let finderWindows = windows.filter {
                ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier &&
                ($0[kCGWindowLayer as String] as? Int) == 0
            }
            if finderWindows.isEmpty {
                Log.info("📌 Desktop detected (Finder, no windows) — no paste target")
                return false
            }
        }
        
        // For any other app with windows, assume paste will work
        return true
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
