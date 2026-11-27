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
        pasteImpl(text, captureForLearning: false).pasted
    }

    /// Pastes text and returns a pre-paste witness for asynchronous confirmation.
    static func pasteForLearning(_ text: String) -> (pasted: Bool, pending: PendingPasteCapture?) {
        pasteImpl(text, captureForLearning: true)
    }

    private static func pasteImpl(
        _ text: String,
        captureForLearning: Bool
    ) -> (pasted: Bool, pending: PendingPasteCapture?) {
        guard !text.isEmpty else { return (false, nil) }
        
        // Check if there's a focused text input BEFORE pasting
        let hasTextInput = checkForTextInput()
        
        // Save current pasteboard content to restore later
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)
        
        // Write our text to pasteboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let writtenChangeCount = pasteboard.changeCount
        
        if hasTextInput, let app = savedApp {
            if shouldActivateSavedApp(
                frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                targetPID: app.processIdentifier
            ) {
                app.activate()
                usleep(150_000)
            }

            let pendingCapture: PendingPasteCapture?
            if captureForLearning {
                pendingCapture = PendingPasteCapture.capture(
                    application: app,
                    insertedText: text
                )
            } else {
                pendingCapture = nil
            }
            
            guard postCommandKey(9, to: app) else {
                Log.info("Paste destination unavailable. Text is on the clipboard.")
                return (false, nil)
            }
            
            // Restore previous pasteboard content after a delay
            if let previous = previousContents {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard shouldRestorePasteboard(
                        currentChangeCount: pasteboard.changeCount,
                        writtenChangeCount: writtenChangeCount
                    ) else { return }
                    pasteboard.clearContents()
                    pasteboard.setString(previous, forType: .string)
                }
            }
            
            Log.info("📋 Pasted \(text.count) chars to cursor")
            return (true, pendingCapture)
        } else {
            // No text input found — text stays on clipboard
            Log.info("📋 No text input focused — copied \(text.count) chars to clipboard")
            return (false, nil)
        }
    }

    static func shouldActivateSavedApp(frontmostPID: pid_t?, targetPID: pid_t) -> Bool {
        frontmostPID != targetPID
    }

    static func shouldRestorePasteboard(currentChangeCount: Int, writtenChangeCount: Int) -> Bool {
        currentChangeCount == writtenChangeCount
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
    
    private static func postCommandKey(_ keyCode: CGKeyCode, to app: NSRunningApplication) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        // Deliver the shortcut to the active login session after confirming its foreground app.
        down.post(tap: .cgSessionEventTap)
        usleep(10_000)
        up.post(tap: .cgSessionEventTap)
        return true
    }

    /// Simulate Cmd+Z in the app that received the dictation.
    static func undo() {
        guard let app = savedApp else { return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            app.activate()
            usleep(50_000)
        }
        _ = postCommandKey(6, to: app)
    }
}
