import AppKit
import ApplicationServices

/// Reads existing text from the focused text field via macOS Accessibility API.
/// Used to provide context to the polisher for more natural output.
///
/// Works best with native macOS apps (Mail, Notes, Messages, TextEdit).
/// Gracefully returns nil for Electron/web apps where AX API doesn't work.
enum ContextReader {
    
    /// Maximum characters of context to capture (before cursor)
    private static let maxContextChars = 500
    
    /// Read input state with cursor position awareness.
    /// Returns text before cursor, text after cursor, and full content.
    /// This allows EditTracker to know exactly where edits happened.
    static func readInputState() -> (beforeCursor: String, afterCursor: String, fullContent: String)? {
        guard let app = PasteService.savedApp else { return nil }
        
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        
        var focusedElement: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard focusResult == .success, let element = focusedElement else { return nil }
        
        let axElement = element as! AXUIElement
        
        var roleValue: AnyObject?
        AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String ?? ""
        
        let textRoles = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField", "AXWebArea"]
        guard textRoles.contains(role) else { return nil }
        
        // Get full text value
        var valueObj: AnyObject?
        let valueResult = AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &valueObj)
        guard valueResult == .success, let fullText = valueObj as? String, !fullText.isEmpty else { return nil }
        
        // Try to get cursor position
        var rangeObj: AnyObject?
        let rangeResult = AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &rangeObj)
        
        if rangeResult == .success, let rangeValue = rangeObj {
            var range = CFRange(location: 0, length: 0)
            if AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) {
                let cursorPos = range.location
                
                // Validate cursor position
                if cursorPos >= 0 && cursorPos <= fullText.count {
                    let cursorIndex = fullText.index(fullText.startIndex, offsetBy: cursorPos)
                    let before = String(fullText[..<cursorIndex])
                    let after = String(fullText[cursorIndex...])
                    
                    return (beforeCursor: before, afterCursor: after, fullContent: fullText)
                }
            }
        }
        
        // Fallback: cursor reading failed, return full text with empty splits
        return (beforeCursor: fullText, afterCursor: "", fullContent: fullText)
    }
    
    /// Read the currently selected text in the focused text field.
    /// Returns nil if no text is selected or AX API fails.
    static func readSelectedText() -> String? {
        guard let app = PasteService.savedApp else { return nil }
        
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        
        var focusedElement: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard focusResult == .success, let element = focusedElement else { return nil }
        
        let axElement = element as! AXUIElement
        
        // Try AX selected text attribute
        var selectedObj: AnyObject?
        let selResult = AXUIElementCopyAttributeValue(axElement, kAXSelectedTextAttribute as CFString, &selectedObj)
        if selResult == .success, let selectedText = selectedObj as? String, !selectedText.isEmpty {
            return selectedText
        }
        
        return nil
    }
    
    /// Read selected text using clipboard simulation (Cmd+C).
    /// Fallback for Electron/web apps where AX API fails.
    /// Saves and restores the original clipboard content.
    static func readSelectedTextViaClipboard() -> String? {
        let pasteboard = NSPasteboard.general
        
        // Save current clipboard
        let oldContents = pasteboard.string(forType: .string)
        let oldChangeCount = pasteboard.changeCount
        
        // Simulate Cmd+C
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)  // 'c'
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
        
        // Wait for clipboard to update
        usleep(100_000)  // 100ms
        
        let newChangeCount = pasteboard.changeCount
        let selectedText: String?
        
        if newChangeCount != oldChangeCount {
            selectedText = pasteboard.string(forType: .string)
            // Restore original clipboard
            pasteboard.clearContents()
            if let old = oldContents {
                pasteboard.setString(old, forType: .string)
            }
        } else {
            selectedText = nil
        }
        
        return selectedText?.isEmpty == true ? nil : selectedText
    }
    
    /// Read the FULL text content of the currently focused text field.
    /// Used by EditTracker to monitor post-paste edits.
    /// Unlike readContext(), this returns the entire field value without truncation.
    static func readFullContent() -> String? {
        guard let app = PasteService.savedApp else { return nil }
        
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        
        var focusedElement: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard focusResult == .success, let element = focusedElement else { return nil }
        
        let axElement = element as! AXUIElement
        
        var roleValue: AnyObject?
        AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String ?? ""
        
        let textRoles = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField", "AXWebArea"]
        guard textRoles.contains(role) else { return nil }
        
        var valueObj: AnyObject?
        let valueResult = AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &valueObj)
        guard valueResult == .success, let fullText = valueObj as? String, !fullText.isEmpty else { return nil }
        
        return fullText
    }
    
    /// Read text from the currently focused text field.
    /// Returns the text before the cursor position (up to maxContextChars),
    /// or nil if reading fails.
    static func readContext() -> String? {
        // Get the focused app's AX element
        guard let app = PasteService.savedApp else {
            Log.info("📖 Context: no saved app")
            return nil
        }
        
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        
        // Get the focused UI element
        var focusedElement: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        
        guard focusResult == .success, let element = focusedElement else {
            Log.info("📖 Context: cannot get focused element (\(focusResult.rawValue))")
            return nil
        }
        
        let axElement = element as! AXUIElement
        
        // Check the role — we only want text areas and text fields
        var roleValue: AnyObject?
        AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String ?? ""
        
        let textRoles = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField", "AXWebArea"]
        guard textRoles.contains(role) else {
            Log.info("📖 Context: focused element is \(role), not a text field")
            return nil
        }
        
        // Get the full text value
        var valueObj: AnyObject?
        let valueResult = AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &valueObj)
        
        guard valueResult == .success, let fullText = valueObj as? String, !fullText.isEmpty else {
            Log.info("📖 Context: no text value in focused element")
            return nil
        }
        
        // Try to get cursor position to extract text BEFORE cursor
        var rangeObj: AnyObject?
        let rangeResult = AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &rangeObj)
        
        var textBeforeCursor: String
        
        if rangeResult == .success, let rangeValue = rangeObj {
            // Extract the CFRange from the AXValue
            var range = CFRange(location: 0, length: 0)
            if AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) {
                let cursorPosition = range.location
                if cursorPosition > 0 && cursorPosition <= fullText.count {
                    let endIndex = fullText.index(fullText.startIndex, offsetBy: min(cursorPosition, fullText.count))
                    textBeforeCursor = String(fullText[..<endIndex])
                } else {
                    // Cursor at start or invalid — use full text
                    textBeforeCursor = fullText
                }
            } else {
                textBeforeCursor = fullText
            }
        } else {
            // Can't get cursor position — use full text (last N chars)
            textBeforeCursor = fullText
        }
        
        // Trim to max length (keep the END, which is closest to cursor)
        if textBeforeCursor.count > maxContextChars {
            let startIndex = textBeforeCursor.index(textBeforeCursor.endIndex, offsetBy: -maxContextChars)
            textBeforeCursor = "..." + String(textBeforeCursor[startIndex...])
        }
        
        let trimmed = textBeforeCursor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            Log.info("📖 Context: text field is empty")
            return nil
        }
        
        Log.info("📖 Context: captured \(trimmed.count) chars from \(role) in \(app.localizedName ?? "?")")
        return trimmed
    }
}
