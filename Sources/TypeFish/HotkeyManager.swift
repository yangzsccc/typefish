import AppKit
import Carbon

enum HotkeyEventTapDecision: Equatable {
    case passThrough
    case cancelAndPassThrough
    case replayedTrackedEnter
    case interceptTrackedEnter
    case trackAndPassThrough(EditMirrorEvent, triggerEnter: Bool)
}

enum ToggleHotkeyTapDecision: Equatable {
    case passThrough
    case consume
    case consumeAndLatch
    case consumeAndToggle
}

/// Global hotkey manager.
/// Claims the dictation shortcut before the focused app handles it. Carbon handles
/// the other shortcuts. Edit tracking has its own temporary event tap.
class HotkeyManager {
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var toggleEventTap: CFMachPort?
    private var toggleRunLoopSource: CFRunLoopSource?
    private var isConsumingToggleKeySequence = false
    private var hasOrphanedToggleKeyUp = false
    private var hotkeyHandler: EventHandlerRef?
    private var hotkeyRefs: [EventHotKeyRef] = []
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    
    /// Called when the hotkey is pressed (Option+Space)
    var onToggle: (() -> Void)?
    
    /// Called when translate hotkey is pressed (Control+Option+Space)
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
    var isTrackingEdits: Bool = false {
        didSet {
            guard oldValue != isTrackingEdits else { return }
            if isTrackingEdits {
                startEditEventTapIfNeeded()
            } else {
                stopEditEventTap()
            }
        }
    }

    private var isReplayingTrackedEnter = false
    
    // Singleton needed because CGEvent tap callback is a C function pointer
    static var shared: HotkeyManager?
    private static let hotkeySignature: OSType = 0x54594648 // "TYFH"

    private enum RegisteredHotkey: UInt32 {
        case toggleRecording = 1
        case translateToggle = 2
        case commandToggle = 3
    }
    
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
        
        let hasActiveToggleTap = startToggleEventTap()
        installRegisteredHotkeys(registerCarbonToggle: !hasActiveToggleTap)
        startPassiveEscapeMonitor()

        Log.info("✅ Hotkey active: Option+Space to toggle recording")
    }

    private func installRegisteredHotkeys(registerCarbonToggle: Bool) {
        guard hotkeyHandler == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            HotkeyManager.registeredHotkeyCallback,
            1,
            &eventType,
            nil,
            &hotkeyHandler
        )

        guard handlerStatus == noErr else {
            Log.info("❌ Failed to install Carbon hotkey handler: \(handlerStatus)")
            return
        }

        if registerCarbonToggle {
            registerHotkey(.toggleRecording, modifiers: UInt32(optionKey))
        }
        registerHotkey(.translateToggle, modifiers: UInt32(controlKey | optionKey))
        registerHotkey(.commandToggle, modifiers: UInt32(controlKey | optionKey | cmdKey))
    }

    /// Consume only the Option+Space key sequence before applications such as ChatGPT
    /// can interpret it as a window-switching shortcut. All other events pass through.
    private func startToggleEventTap() -> Bool {
        guard toggleEventTap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: HotkeyManager.toggleEventTapCallback,
            userInfo: nil
        ) else {
            Log.info("⚠️ Could not create Option+Space suppression tap; using Carbon hotkey fallback.")
            return false
        }

        toggleEventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        toggleRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.info("Option+Space focus protection active")
        return true
    }

    private func stopToggleEventTap() {
        if let tap = toggleEventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = toggleRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        toggleEventTap = nil
        toggleRunLoopSource = nil
        isConsumingToggleKeySequence = false
        hasOrphanedToggleKeyUp = false
    }

    static let toggleEventTapCallback: CGEventTapCallBack = { _, type, event, _ in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let manager = HotkeyManager.shared {
                if manager.isConsumingToggleKeySequence {
                    manager.hasOrphanedToggleKeyUp = true
                    manager.isConsumingToggleKeySequence = false
                }
            }
            if let tap = HotkeyManager.shared?.toggleEventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let manager = HotkeyManager.shared else { return Unmanaged.passUnretained(event) }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
            .intersection([.command, .shift, .control, .option, .function])
        let decision = toggleTapDecision(
            eventType: type,
            keyCode: keyCode,
            modifiers: modifiers,
            isConsumingSequence: manager.isConsumingToggleKeySequence,
            hasOrphanedKeyUp: manager.hasOrphanedToggleKeyUp,
            isAutorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        )
        switch decision {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .consume:
            if type == .keyUp {
                manager.isConsumingToggleKeySequence = false
                manager.hasOrphanedToggleKeyUp = false
            }
            return nil
        case .consumeAndLatch:
            manager.isConsumingToggleKeySequence = true
            return nil
        case .consumeAndToggle:
            manager.isConsumingToggleKeySequence = true
            DispatchQueue.main.async { HotkeyManager.shared?.onToggle?() }
            return nil
        }
    }

    private func registerHotkey(_ hotkey: RegisteredHotkey, modifiers: UInt32) {
        let hotkeyID = EventHotKeyID(signature: Self.hotkeySignature, id: hotkey.rawValue)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_Space),
            modifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        if status == noErr, let ref {
            hotkeyRefs.append(ref)
        } else {
            Log.info("❌ Failed to register hotkey \(hotkey): \(status)")
        }
    }

    private static let registeredHotkeyCallback: EventHandlerUPP = { _, event, _ in
        guard let event else { return noErr }

        var hotkeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotkeyID
        )

        guard status == noErr, hotkeyID.signature == HotkeyManager.hotkeySignature else {
            return noErr
        }

        DispatchQueue.main.async {
            HotkeyManager.shared?.handleRegisteredHotkey(id: hotkeyID.id)
        }

        return noErr
    }

    private func handleRegisteredHotkey(id: UInt32) {
        guard let hotkey = RegisteredHotkey(rawValue: id) else { return }

        switch hotkey {
        case .toggleRecording:
            onToggle?()
        case .translateToggle:
            onTranslateToggle?()
        case .commandToggle:
            onCommandToggle?()
        }
    }

    private func startPassiveEscapeMonitor() {
        guard globalKeyMonitor == nil, localKeyMonitor == nil else { return }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handlePassiveKey(event)
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handlePassiveKey(event)
            return event
        }
    }

    private func handlePassiveKey(_ event: NSEvent) {
        let meaningful = event.modifierFlags.intersection([.command, .shift, .control, .option])
        guard event.keyCode == 53, meaningful.isEmpty else { return }

        DispatchQueue.main.async { [weak self] in
            self?.onCancel?()
        }
    }

    private func startEditEventTapIfNeeded() {
        guard eventTap == nil else { return }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: HotkeyManager.eventTapCallback,
            userInfo: nil
        ) else {
            Log.info("❌ Failed to create edit tracking CGEvent tap. Check Accessibility permissions.")
            return
        }

        self.eventTap = tap
        self.runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopEditEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }
    
    /// C callback for CGEvent tap
    static let eventTapCallback: CGEventTapCallBack = { proxy, type, event, userInfo in
        // Re-enable tap if system disabled it
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = HotkeyManager.shared?.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        
        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }
        
        guard let manager = HotkeyManager.shared else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let meaningful = NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))
            .intersection([.command, .shift, .control, .option])

        let decision = eventTapDecision(
            keyCode: keyCode,
            characters: characters(from: event),
            modifiers: meaningful,
            isTrackingEdits: manager.isTrackingEdits,
            isReplayingTrackedEnter: manager.isReplayingTrackedEnter,
            shouldInterceptEnter: manager.shouldInterceptEnterForEditTracking?() == true
        )

        switch decision {
        case .passThrough:
            return Unmanaged.passUnretained(event)

        case .cancelAndPassThrough:
            DispatchQueue.main.async {
                HotkeyManager.shared?.onCancel?()
            }
            return Unmanaged.passUnretained(event)

        case .replayedTrackedEnter:
            manager.isReplayingTrackedEnter = false
            return Unmanaged.passUnretained(event)

        case .interceptTrackedEnter:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                HotkeyManager.shared?.onInterceptedEnterKey?()
            }
            return nil

        case .trackAndPassThrough(let mirrorEvent, let triggerEnter):
            DispatchQueue.main.async {
                if triggerEnter {
                    HotkeyManager.shared?.onEnterKey?()
                }
                HotkeyManager.shared?.onTrackedKeyEvent?(mirrorEvent)
                HotkeyManager.shared?.onAnyKeyPress?()
            }
            return Unmanaged.passUnretained(event)
        }
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
        isTrackingEdits = false
        stopEditEventTap()
        stopToggleEventTap()

        for ref in hotkeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotkeyRefs.removeAll()

        if let handler = hotkeyHandler {
            RemoveEventHandler(handler)
        }
        hotkeyHandler = nil

        if let monitor = globalKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        globalKeyMonitor = nil
        localKeyMonitor = nil

        onInterceptedEnterKey = nil
        shouldInterceptEnterForEditTracking = nil
        onTrackedKeyEvent = nil
        HotkeyManager.shared = nil
    }
    
    deinit { stop() }

    static func toggleTapDecisionForTesting(
        eventType: CGEventType,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        isConsumingSequence: Bool,
        hasOrphanedKeyUp: Bool = false,
        isAutorepeat: Bool = false
    ) -> ToggleHotkeyTapDecision {
        toggleTapDecision(eventType: eventType, keyCode: keyCode, modifiers: modifiers,
                          isConsumingSequence: isConsumingSequence,
                          hasOrphanedKeyUp: hasOrphanedKeyUp,
                          isAutorepeat: isAutorepeat)
    }

    private static func toggleTapDecision(
        eventType: CGEventType,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        isConsumingSequence: Bool,
        hasOrphanedKeyUp: Bool,
        isAutorepeat: Bool
    ) -> ToggleHotkeyTapDecision {
        if eventType == .keyUp && keyCode == UInt16(kVK_Space) {
            return isConsumingSequence || hasOrphanedKeyUp ? .consume : .passThrough
        }
        guard eventType == .keyDown, keyCode == UInt16(kVK_Space) else { return .passThrough }
        if isConsumingSequence { return .consume }
        guard modifiers == [.option] else { return .passThrough }
        if isAutorepeat { return .consumeAndLatch }
        return .consumeAndToggle
    }

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

    static func eventTapDecisionForTesting(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        isTrackingEdits: Bool,
        isReplayingTrackedEnter: Bool,
        shouldInterceptEnter: Bool
    ) -> HotkeyEventTapDecision {
        eventTapDecision(
            keyCode: keyCode,
            characters: testCharacters(for: keyCode),
            modifiers: modifiers,
            isTrackingEdits: isTrackingEdits,
            isReplayingTrackedEnter: isReplayingTrackedEnter,
            shouldInterceptEnter: shouldInterceptEnter
        )
    }

    private static func eventTapDecision(
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags,
        isTrackingEdits: Bool,
        isReplayingTrackedEnter: Bool,
        shouldInterceptEnter: Bool
    ) -> HotkeyEventTapDecision {
        if keyCode == 53 && modifiers.isEmpty {
            return .cancelAndPassThrough
        }

        if isRegisteredSpaceHotkey(keyCode: keyCode, modifiers: modifiers) {
            return .passThrough
        }

        guard isTrackingEdits else {
            return .passThrough
        }

        if keyCode == 36 && modifiers.isEmpty {
            if isReplayingTrackedEnter {
                return .replayedTrackedEnter
            }

            if shouldInterceptEnter {
                return .interceptTrackedEnter
            }
        }

        let mirrorEvent = EditMirrorEvent.fromKeyEvent(
            keyCode: keyCode,
            characters: characters,
            modifiers: modifiers
        )
        return .trackAndPassThrough(mirrorEvent, triggerEnter: keyCode == 36 && modifiers.isEmpty)
    }

    private static func testCharacters(for keyCode: UInt16) -> String {
        switch keyCode {
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 23: return "5"
        default: return ""
        }
    }

    private static func isRegisteredSpaceHotkey(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard keyCode == 49 else { return false }
        return modifiers == [.option]
            || modifiers == [.control, .option]
            || modifiers == [.control, .option, .command]
    }
}
