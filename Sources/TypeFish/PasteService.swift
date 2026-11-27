import AppKit

private final class PasteConfirmationResult: @unchecked Sendable {
    private let lock = NSLock()
    private var anchor: PostPasteCaptureAnchor?
    private let previousContents: String?
    private let writtenChangeCount: Int
    private let onConfirmation: (PostPasteCaptureAnchor?) -> Void

    init(previousContents: String?, writtenChangeCount: Int,
         onConfirmation: @escaping (PostPasteCaptureAnchor?) -> Void) {
        self.previousContents = previousContents
        self.writtenChangeCount = writtenChangeCount
        self.onConfirmation = onConfirmation
    }

    func store(_ anchor: PostPasteCaptureAnchor?) {
        lock.lock()
        self.anchor = anchor
        lock.unlock()
    }

    func deliverOnMain() {
        lock.lock()
        let anchor = self.anchor
        lock.unlock()

        if anchor != nil, let previousContents {
            PasteService.restorePasteboardIfUnchanged(
                previousContents: previousContents,
                writtenChangeCount: writtenChangeCount
            )
        }
        onConfirmation(anchor)
    }
}

enum PasteDeliveryStatus {
    case confirming
    case confirmed
    case copyAvailable

    var message: String {
        switch self {
        case .confirming: return "⏳ Confirming insertion..."
        case .confirmed: return "✅ Done"
        case .copyAvailable: return "📋 Paste not confirmed — result ready to copy"
        }
    }
}

/// Pastes text at the current cursor position.
/// Tracks the frontmost app and restores focus before pasting.
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
        pasteImpl(text, captureForLearning: false).pasted
    }

    /// Pastes text and returns a pre-paste witness for asynchronous confirmation.
    static func pasteForLearning(
        _ text: String,
        onConfirmation: ((PostPasteCaptureAnchor?) -> Void)? = nil
    ) -> (pasted: Bool, pending: PendingPasteCapture?) {
        pasteImpl(text, captureForLearning: true, onConfirmation: onConfirmation)
    }

    private static func pasteImpl(
        _ text: String,
        captureForLearning: Bool,
        onConfirmation: ((PostPasteCaptureAnchor?) -> Void)? = nil
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
                return (false, nil)
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
                    return (false, nil)
                case .unavailable:
                    break
                }
            }

            if !commandDispatched, !postCommandKey(9, to: app) {
                Log.info("Paste destination unavailable. Text is on the clipboard.")
                return (false, nil)
            }
            
            // Restore previous pasteboard content after a delay
            if let onConfirmation {
                guard let pendingCapture else {
                    DispatchQueue.main.async { onConfirmation(nil) }
                    Log.info("Paste was sent, but its destination could not be verified")
                    return (true, nil)
                }

                let result = PasteConfirmationResult(
                    previousContents: previousContents,
                    writtenChangeCount: writtenChangeCount,
                    onConfirmation: onConfirmation
                )
                Task.detached(priority: .utility) {
                    let deadline = ProcessInfo.processInfo.systemUptime + 2
                    var anchor: PostPasteCaptureAnchor?
                    repeat {
                        if let confirmed = pendingCapture.confirm() {
                            anchor = confirmed
                            break
                        }
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    } while ProcessInfo.processInfo.systemUptime < deadline

                    result.store(anchor)
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
