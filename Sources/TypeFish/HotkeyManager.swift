import AppKit
import Carbon

/// Global hotkey manager using CGEvent tap.
/// Listens for Option+Space to toggle recording.
/// Swallows the event so it doesn't trigger Spotlight or other system actions.
class HotkeyManager {
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var watchdogTimer: Timer?
    
    /// Called when the hotkey is pressed (Option+Space)
    var onToggle: (() -> Void)?
    
    /// Called when translate hotkey is pressed (Option+Shift+Space)
    var onTranslateToggle: (() -> Void)?
    
    /// Called when Escape is pressed (cancel recording)
    var onCancel: (() -> Void)?
    
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
        
        // Watchdog: periodically check if event tap is still alive
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self = self, let tap = self.eventTap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                Log.info("🔧 Watchdog: re-enabling event tap")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
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
        
        return Unmanaged.passRetained(event)
    }
    
    func stop() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        HotkeyManager.shared = nil
    }
    
    deinit { stop() }
}
