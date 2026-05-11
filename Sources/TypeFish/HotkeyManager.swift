import AppKit
import Carbon

/// Global hotkey manager using CGEvent tap.
/// Listens for Option+Space to toggle recording.
/// Swallows the event so it doesn't trigger Spotlight or other system actions.
class HotkeyManager {
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    
    /// Called when the hotkey is pressed (Option+Space)
    var onToggle: (() -> Void)?
    
    /// Called when translate hotkey is pressed (Option+Shift+Space)
    var onTranslateToggle: (() -> Void)?
    
    /// Called when AI command hotkey is pressed (Ctrl+Option+Cmd+Space)
    var onCommandToggle: (() -> Void)?
    
    /// Called when Escape is pressed (cancel recording)
    var onCancel: (() -> Void)?
    
    /// Called on any keypress when EditTracker is active
    var onAnyKeyPress: (() -> Void)?

    /// Called with a normalized key event when EditTracker is active.
    var onTrackedKeyEvent: ((EditMirrorEvent) -> Void)?
    
    /// Called when Enter key is pressed (for immediate analysis)
    var onEnterKey: (() -> Void)?

    /// Called when Enter is intercepted so EditTracker can snapshot before the draft is sent.
    var onInterceptedEnterKey: (() -> Void)?

    /// Returns true when EditTracker wants to hold Enter briefly for a before-send snapshot.
    var shouldInterceptEnterForEditTracking: (() -> Bool)?
    
    /// Flag to enable/disable keypress tracking for EditTracker
    var isTrackingEdits: Bool = false

    private var isReplayingTrackedEnter = false
    
    // Singleton needed because CGEvent tap callback is a C function pointer
    static var shared: HotkeyManager?
    
    func start() {
        HotkeyManager.shared = self
        
        // Check accessibility permissions
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        
        if !trusted {
            Log.info("⚠️ Accessibility permission needed!")
            Log.info("Go to: System Settings → Privacy & Security → Accessibility")
            Log.info("Add this app, then restart.")
        } else {
            Log.info("✅ Accessibility permission granted")
        }
        
        // Create event tap for key down events
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: HotkeyManager.eventTapCallback,
            userInfo: nil
        ) else {
            Log.info("❌ Failed to create CGEvent tap. Check Accessibility permissions.")
            return
        }
        
        self.eventTap = tap
        self.runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        
        Log.info("✅ Hotkey active: Option+Space to toggle recording")
    }
    
    /// C callback for CGEvent tap
    static let eventTapCallback: CGEventTapCallBack = { proxy, type, event, userInfo in
        // Re-enable tap if system disabled it
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = HotkeyManager.shared?.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }
        
        guard type == .keyDown else {
            return Unmanaged.passRetained(event)
        }
        
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let meaningful = NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))
            .intersection([.command, .shift, .control, .option])
        
        // Ctrl+Option+Cmd+Space — AI command mode
        if meaningful == [.control, .option, .command] && keyCode == 49 {
            DispatchQueue.main.async {
                HotkeyManager.shared?.onCommandToggle?()
            }
            return nil  // Swallow the event
        }
        
        // Ctrl+Option+Space (keyCode 49 = Space) — translate mode
        if meaningful == [.control, .option] && keyCode == 49 {
            DispatchQueue.main.async {
                HotkeyManager.shared?.onTranslateToggle?()
            }
            return nil  // Swallow the event
        }
        
        // Option+Space (keyCode 49 = Space) — normal transcribe
        if meaningful == [.option] && keyCode == 49 {
            DispatchQueue.main.async {
                HotkeyManager.shared?.onToggle?()
            }
            return nil  // Swallow the event
        }
        
        // Escape (keyCode 53) — cancel recording
        if keyCode == 53 && meaningful.isEmpty {
            DispatchQueue.main.async {
                HotkeyManager.shared?.onCancel?()
            }
            // Don't swallow Escape — let it propagate to other apps too
            return Unmanaged.passRetained(event)
        }
        
        // Enter key (keyCode 36) — immediate analysis when tracking edits.
        if keyCode == 36 && meaningful.isEmpty && HotkeyManager.shared?.isTrackingEdits == true {
            if HotkeyManager.shared?.isReplayingTrackedEnter == true {
                HotkeyManager.shared?.isReplayingTrackedEnter = false
                return Unmanaged.passRetained(event)
            }

            if HotkeyManager.shared?.shouldInterceptEnterForEditTracking?() == true {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    HotkeyManager.shared?.onInterceptedEnterKey?()
                }
                return nil
            }

            DispatchQueue.main.async {
                HotkeyManager.shared?.onEnterKey?()
            }
        }
        
        // If EditTracker is active, send the key details first, then fire the legacy callback.
        if HotkeyManager.shared?.isTrackingEdits == true {
            let characters = characters(from: event)
            let mirrorEvent = EditMirrorEvent.fromKeyEvent(
                keyCode: keyCode,
                characters: characters,
                modifiers: meaningful
            )
            DispatchQueue.main.async {
                HotkeyManager.shared?.onTrackedKeyEvent?(mirrorEvent)
                HotkeyManager.shared?.onAnyKeyPress?()
            }
        }
        
        return Unmanaged.passRetained(event)
    }

    func replayEnterForEditTracking() {
        isReplayingTrackedEnter = true

        let source = CGEventSource(stateID: .hidSystemState)
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true) {
            keyDown.post(tap: .cghidEventTap)
        }
        usleep(10_000)
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false) {
            keyUp.post(tap: .cghidEventTap)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.isReplayingTrackedEnter = false
        }
    }
    
    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        onInterceptedEnterKey = nil
        shouldInterceptEnterForEditTracking = nil
        onTrackedKeyEvent = nil
        HotkeyManager.shared = nil
    }
    
    deinit { stop() }

    private static func characters(from event: CGEvent) -> String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 16)
        event.keyboardGetUnicodeString(
            maxStringLength: buffer.count,
            actualStringLength: &length,
            unicodeString: &buffer
        )
        guard length > 0 else { return "" }
        return String(utf16CodeUnits: buffer, count: length)
    }
}
