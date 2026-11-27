import AppKit

private final class PasteConfirmationResult: @unchecked Sendable {
    private let lock = NSLock()
    private var confirmation: PasteCaptureConfirmation?
    private let previousContents: String?
    private let writtenChangeCount: Int
    private let onConfirmation: (PasteCaptureConfirmation?) -> Void

    init(previousContents: String?, writtenChangeCount: Int,
         onConfirmation: @escaping (PasteCaptureConfirmation?) -> Void) {
        self.previousContents = previousContents
        self.writtenChangeCount = writtenChangeCount
        self.onConfirmation = onConfirmation
    }

    func store(_ confirmation: PasteCaptureConfirmation?) {
        lock.lock()
        self.confirmation = confirmation
        lock.unlock()
    }

    func deliverOnMain() {
        lock.lock()
        let confirmation = self.confirmation
        lock.unlock()

        if confirmation?.deliveryConfirmed == true, let previousContents {
            PasteService.restorePasteboardIfUnchanged(
                previousContents: previousContents,
                writtenChangeCount: writtenChangeCount
            )
        }
        onConfirmation(confirmation)
    }
}

enum PasteDispatch {
    case sent, noInput, destinationUnavailable
}

enum PasteDeliveryStatus {
    case confirming
    case confirmed
    case copyAvailable
    case unconfirmed

    var message: String {
        switch self {
        case .confirming: return "⏳ Confirming insertion..."
        case .confirmed: return "✅ Done"
        case .copyAvailable: return "📋 Paste not confirmed — result ready to copy"
        case .unconfirmed: return "⚠️ Insertion could not be verified"
        }
    }
}

enum PasteTargetAccessibility {
    enum FocusedElementAssessment: Equatable {
        case editable
        case nonEditable
        case unknown
    }

    private static let editableRoles: Set<String> = [
        "AXComboBox",
        "AXSearchField",
        "AXSecureTextField",
        "AXTextArea",
        "AXTextField",
        "AXTextView"
    ]

    private static let nonEditableRoles: Set<String> = [
        "AXButton",
        "AXCheckBox",
        "AXImage",
        "AXMenu",
        "AXMenuBar",
        "AXMenuBarItem",
        "AXMenuButton",
        "AXMenuItem",
        "AXPopUpButton",
        "AXRadioButton",
        "AXRow",
        "AXSlider",
        "AXStaticText",
        "AXSwitch",
        "AXTabGroup",
        "AXToolbar",
        "AXWindow"
    ]

    private static let ambiguousRoles: Set<String> = [
        "AXCell",
        "AXGroup",
        "AXList",
        "AXOutline",
        "AXScrollArea",
        "AXSplitGroup",
        "AXSplitter",
        "AXTable",
        "AXWebArea"
    ]

    static func assessment(
        role: String?,
        valueIsSettable: Bool,
        selectedTextIsSettable: Bool
    ) -> FocusedElementAssessment {
        guard let role else { return .unknown }
        if editableRoles.contains(role) { return .editable }
        if ambiguousRoles.contains(role) {
            return valueIsSettable || selectedTextIsSettable ? .editable : .unknown
        }
        if nonEditableRoles.contains(role) { return .nonEditable }
        return .unknown
    }
}

/// Pastes text at the current cursor position.
/// Delivers only while the original application still has focus.
enum PasteService {
    
    /// The app that was active when recording started
    private(set) static var savedApp: NSRunningApplication?
    private static let targetLock = NSLock()
    private static var targetCaptureID = UUID()
    private static var recordedTarget: AccessibilityTargetIdentity?
    private static var recordedNativePasteCommand: NativePasteCommand?
    
    /// Save reference to the currently focused app (call when recording starts)
    static func saveFrontmostApp() {
        savedApp = NSWorkspace.shared.frontmostApplication
        let captureID = UUID()
        targetLock.lock()
        targetCaptureID = captureID
        recordedTarget = nil
        recordedNativePasteCommand = nil
        targetLock.unlock()

        guard let app = savedApp else { return }
        Log.info("📌 Saved frontmost app: \(app.localizedName ?? "unknown") (pid: \(app.processIdentifier))")
        DispatchQueue.global(qos: .userInitiated).async {
            let target = PendingPasteCapture.focusedTarget(in: app)
            targetLock.lock()
            if targetCaptureID == captureID {
                recordedTarget = target
            }
            targetLock.unlock()

            let pasteCommand = requiresVerifiedTarget(for: app.bundleIdentifier)
                ? NativePasteCommand.find(in: app)
                : nil
            targetLock.lock()
            if targetCaptureID == captureID {
                recordedNativePasteCommand = pasteCommand
            }
            targetLock.unlock()
        }
    }
    
    /// Paste text at current cursor position in the saved app.
    /// Returns true if paste was likely successful (a text field was focused).
    @discardableResult
    static func paste(_ text: String) -> Bool {
        pasteImpl(text, captureForLearning: false).dispatch == .sent
    }

    /// Pastes text and returns a pre-paste witness for asynchronous confirmation.
    static func pasteForLearning(
        _ text: String,
        onConfirmation: ((PasteCaptureConfirmation?) -> Void)? = nil
    ) -> (dispatch: PasteDispatch, pending: PendingPasteCapture?) {
        pasteImpl(text, captureForLearning: true, onConfirmation: onConfirmation)
    }

    private static func pasteImpl(
        _ text: String,
        captureForLearning: Bool,
        onConfirmation: ((PasteCaptureConfirmation?) -> Void)? = nil
    ) -> (dispatch: PasteDispatch, pending: PendingPasteCapture?) {
        guard !text.isEmpty else { return (.destinationUnavailable, nil) }
        
        // Check if there's a focused text input BEFORE pasting
        let targetKind = assessInputTarget()
        
        // Save current pasteboard content to restore later
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)
        
        // Write our text to pasteboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let writtenChangeCount = pasteboard.changeCount
        
        if targetKind != .nonEditable, let app = savedApp {
            guard isSavedApplicationFrontmost(
                frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                targetPID: app.processIdentifier
            ) else {
                Log.info("Paste skipped: the original app is no longer frontmost; result is on the clipboard")
                return (.destinationUnavailable, nil)
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

            let recordingTarget = recordingTargetSnapshot()
            let expectedTarget = recordingTarget.target
            let strictTargetBinding = captureForLearning && requiresVerifiedTarget(for: app.bundleIdentifier)
            let targetMatches = expectedTarget.flatMap { target in
                pendingCapture.map { $0.matches(target) }
            } ?? true
            guard shouldPostPaste(
                requiresVerifiedTarget: strictTargetBinding,
                hasRecordingTarget: expectedTarget != nil,
                hasPasteTarget: pendingCapture != nil,
                targetsMatch: targetMatches
            ) else {
                Log.info("Paste skipped: the dictation destination could not be matched to the recording field")
                let noInput = targetKind == .unknown && pendingCapture == nil && expectedTarget == nil
                return (noInput ? .noInput : .destinationUnavailable, nil)
            }
            
            var commandDispatched = false
            if captureForLearning,
               requiresVerifiedTarget(for: app.bundleIdentifier),
               let pendingCapture,
               let nativeCommand = recordingTarget.nativePasteCommand {
                switch pendingCapture.performNativePasteIfUnchanged(nativeCommand) {
                case .dispatched, .uncertain:
                    commandDispatched = true
                case .targetChanged:
                    Log.info("Paste skipped: ChatGPT field changed before its native paste command")
                    return (.destinationUnavailable, nil)
                case .unavailable:
                    break
                }
            }

            if !commandDispatched, !postCommandKey(9, to: app) {
                Log.info("Paste destination unavailable. Text is on the clipboard.")
                return (.destinationUnavailable, nil)
            }
            
            // Restore previous pasteboard content after a delay
            if let onConfirmation {
                guard let pendingCapture else {
                    DispatchQueue.main.async { onConfirmation(nil) }
                    Log.info("Paste was sent, but its destination could not be verified")
                    return (.sent, nil)
                }

                let result = PasteConfirmationResult(
                    previousContents: previousContents,
                    writtenChangeCount: writtenChangeCount,
                    onConfirmation: onConfirmation
                )
                Task.detached(priority: .utility) {
                    let deadline = ProcessInfo.processInfo.systemUptime + 2
                    var confirmation: PasteCaptureConfirmation?
                    repeat {
                        if let confirmed = pendingCapture.confirm() {
                            confirmation = confirmed
                            break
                        }
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    } while ProcessInfo.processInfo.systemUptime < deadline

                    if confirmation == nil {
                        Log.info("Paste confirmation timed out: \(pendingCapture.lastConfirmationFailure)")
                    }
                    result.store(confirmation)
                    DispatchQueue.main.async { result.deliverOnMain() }
                }
            } else if let previous = previousContents {
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
            return (.sent, pendingCapture)
        } else {
            // No text input found — text stays on clipboard
            Log.info("📋 No text input focused — copied \(text.count) chars to clipboard")
            return (.noInput, nil)
        }
    }

    static func isSavedApplicationFrontmost(frontmostPID: pid_t?, targetPID: pid_t) -> Bool {
        frontmostPID == targetPID
    }

    static func requiresVerifiedTarget(for bundleIdentifier: String?) -> Bool {
        bundleIdentifier == "com.openai.codex"
    }

    static func shouldPostPaste(
        requiresVerifiedTarget: Bool,
        hasRecordingTarget: Bool,
        hasPasteTarget: Bool,
        targetsMatch: Bool
    ) -> Bool {
        guard targetsMatch else { return false }
        return !requiresVerifiedTarget || (hasRecordingTarget && hasPasteTarget)
    }

    private struct RecordingTargetSnapshot {
        let target: AccessibilityTargetIdentity?
        let nativePasteCommand: NativePasteCommand?
    }

    private static func recordingTargetSnapshot() -> RecordingTargetSnapshot {
        targetLock.lock()
        defer { targetLock.unlock() }
        return RecordingTargetSnapshot(
            target: recordedTarget,
            nativePasteCommand: recordedNativePasteCommand
        )
    }

    static func shouldRestorePasteboard(currentChangeCount: Int, writtenChangeCount: Int) -> Bool {
        currentChangeCount == writtenChangeCount
    }

    static func shouldRestorePasteboardAfterConfirmation(
        confirmed: Bool,
        currentChangeCount: Int,
        writtenChangeCount: Int
    ) -> Bool {
        confirmed && shouldRestorePasteboard(
            currentChangeCount: currentChangeCount,
            writtenChangeCount: writtenChangeCount
        )
    }

    fileprivate static func restorePasteboardIfUnchanged(
        previousContents: String,
        writtenChangeCount: Int
    ) {
        guard shouldRestorePasteboardAfterConfirmation(
            confirmed: true,
            currentChangeCount: NSPasteboard.general.changeCount,
            writtenChangeCount: writtenChangeCount
        ) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(previousContents, forType: .string)
    }
    
    /// Check if there's likely a place to paste.
    private static func assessInputTarget() -> PasteTargetAccessibility.FocusedElementAssessment {
        guard let app = savedApp else { return .nonEditable }
        if let (role, valueIsSettable, selectedTextIsSettable) = focusedElement(in: app) {
            let target = PasteTargetAccessibility.assessment(
                role: role, valueIsSettable: valueIsSettable, selectedTextIsSettable: selectedTextIsSettable
            )
            if target != .unknown { return target }
        }

        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let hasWindow = windows.contains {
            ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0
        }
        // Custom editors can accept paste without exposing their input through Accessibility.
        return hasWindow ? .unknown : .nonEditable
    }

    private static func focusedElement(in app: NSRunningApplication) -> (String?, Bool, Bool)? {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.012)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }

        let element = unsafeBitCast(focusedValue, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.012)
        var roleValue: CFTypeRef?
        let role: String?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success {
            role = roleValue as? String
        } else {
            role = nil
        }
        guard PasteTargetAccessibility.assessment(role: role, valueIsSettable: false, selectedTextIsSettable: false) == .unknown else {
            return (role, false, false)
        }
        return (
            role,
            isAttributeSettable(kAXValueAttribute as CFString, on: element),
            isAttributeSettable(kAXSelectedTextAttribute as CFString, on: element)
        )
    }

    private static func isAttributeSettable(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute, &settable) == .success && settable.boolValue
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
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
        _ = postCommandKey(6, to: app)
    }
}
