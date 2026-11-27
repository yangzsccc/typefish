import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum AnchoredEditObservation: Equatable {
    case text(String)
    case temporarilyUnavailable
    case unavailable
    case composing
    case cleared
}

struct TextFieldSnapshot {
    let text: String
    let selectedRange: NSRange
    let markedTextStatus: MarkedTextStatus

    init(text: String, selectedRange: NSRange, hasMarkedText: Bool) {
        self.text = text
        self.selectedRange = selectedRange
        self.markedTextStatus = hasMarkedText ? .present : .absent
    }

    init(text: String, selectedRange: NSRange, markedTextStatus: MarkedTextStatus) {
        self.text = text
        self.selectedRange = selectedRange
        self.markedTextStatus = markedTextStatus
    }

    init?(axValue: Any?, selectedRange: NSRange, markedTextStatus: MarkedTextStatus) {
        guard let text = axValue as? String else { return nil }
        self.text = text
        self.selectedRange = selectedRange
        self.markedTextStatus = markedTextStatus
    }
}

enum MarkedTextStatus: Equatable {
    case present
    case absent
    case unavailable
}

struct AnchoredTextRegion: Equatable {
    let prefix: String
    let suffix: String
    let originalText: String

    static func confirmed(
        before: TextFieldSnapshot,
        after: TextFieldSnapshot,
        insertedText: String,
        sameTarget: Bool,
        allowSelectionWithinInsertedText: Bool = false,
        isStructuralEmptyParagraph: Bool = false
    ) -> AnchoredTextRegion? {
        guard sameTarget,
              before.markedTextStatus != .present,
              after.markedTextStatus != .present,
              !insertedText.isEmpty,
              isValidUTF16Range(before.selectedRange, in: before.text),
              isValidUTF16Range(after.selectedRange, in: after.text) else {
            return nil
        }

        let expectedText = (before.text as NSString).replacingCharacters(
            in: before.selectedRange,
            with: insertedText
        )
        // Chromium can consume the trailing BR of an empty ProseMirror paragraph.
        // When the newline survives, the ordinary match retains it as the suffix.
        let replacedStructuralBreak = isStructuralEmptyParagraph
            && before.text == "\n"
            && before.selectedRange == NSRange(location: 0, length: 0)
            && exactlyMatches(after.text, insertedText)
        guard !exactlyMatches(before.text, after.text),
              exactlyMatches(after.text, expectedText) || replacedStructuralBreak else { return nil }

        let insertedRange = NSRange(
            location: before.selectedRange.location,
            length: (insertedText as NSString).length
        )
        let selectionEnd = NSMaxRange(after.selectedRange)
        let selectionWithinInsertion = after.selectedRange.location >= insertedRange.location
            && selectionEnd <= NSMaxRange(insertedRange)
        let selectionAtInsertionEnd = after.selectedRange.location == NSMaxRange(insertedRange)
            && after.selectedRange.length == 0
        guard allowSelectionWithinInsertedText ? selectionWithinInsertion : selectionAtInsertionEnd else {
            return nil
        }
        let afterNSString = after.text as NSString
        let prefix = afterNSString.substring(to: insertedRange.location)
        let suffix = afterNSString.substring(from: NSMaxRange(insertedRange))
        return AnchoredTextRegion(prefix: prefix, suffix: suffix, originalText: insertedText)
    }

    func candidate(in fieldText: String) -> String? {
        candidateRange(in: fieldText).map { (fieldText as NSString).substring(with: $0) }
    }

    func candidate(in fieldText: String, selectedRange: NSRange) -> String? {
        let field = fieldText as NSString
        guard Self.isValidUTF16Range(selectedRange, in: fieldText),
              let candidateRange = candidateRange(in: fieldText),
              selectedRange.location >= candidateRange.location,
              selectedRange.location + selectedRange.length <= NSMaxRange(candidateRange) else {
            return nil
        }
        return field.substring(with: candidateRange)
    }

    private func candidateRange(in fieldText: String) -> NSRange? {
        let field = fieldText as NSString
        let prefixLength = (prefix as NSString).length
        let suffixLength = (suffix as NSString).length
        guard prefixLength <= field.length,
              suffixLength <= field.length - prefixLength else {
            return nil
        }
        let actualPrefix = field.substring(to: prefixLength)
        let actualSuffix = field.substring(from: field.length - suffixLength)
        guard Self.exactlyMatches(actualPrefix, prefix),
              Self.exactlyMatches(actualSuffix, suffix) else { return nil }
        return NSRange(
            location: prefixLength,
            length: field.length - prefixLength - suffixLength
        )
    }

    func observation(
        in fieldText: String,
        selectedRange: NSRange,
        markedTextStatus: MarkedTextStatus,
        isNonDirectInputMethod: Bool
    ) -> AnchoredEditObservation {
        if markedTextStatus == .present { return .composing }
        if markedTextStatus != .absent, isNonDirectInputMethod {
            return .composing
        }
        if fieldText.isEmpty { return .cleared }
        guard let candidate = candidate(in: fieldText, selectedRange: selectedRange) else { return .unavailable }
        return candidate.isEmpty ? .cleared : .text(candidate)
    }

    private static func exactlyMatches(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.elementsEqual(rhs.utf16)
    }

    static func isValidUTF16Range(_ range: NSRange, in text: String) -> Bool {
        let value = text as NSString
        guard range.location >= 0,
              range.length >= 0,
              range.location <= value.length,
              range.length <= value.length - range.location else {
            return false
        }
        return isCharacterBoundary(range.location, in: value)
            && isCharacterBoundary(range.location + range.length, in: value)
    }

    private static func isCharacterBoundary(_ index: Int, in text: NSString) -> Bool {
        guard index > 0, index < text.length else { return true }
        let previous = text.character(at: index - 1)
        let current = text.character(at: index)
        let previousIsHighSurrogate = (0xD800...0xDBFF).contains(previous)
        let currentIsLowSurrogate = (0xDC00...0xDFFF).contains(current)
        return !(previousIsHighSurrogate && currentIsLowSurrogate)
    }
}

private struct AccessibilityFieldSnapshot {
    let target: AccessibilityTargetIdentity
    let text: String
    let selectedRange: NSRange
    let markedTextStatus: MarkedTextStatus
    let isProseMirrorEditor: Bool
    let isProseMirrorStructuralEmpty: Bool

    var textSnapshot: TextFieldSnapshot {
        TextFieldSnapshot(text: text, selectedRange: selectedRange, markedTextStatus: markedTextStatus)
    }
}

private final class SnapshotResultBox {
    private let lock = NSLock()
    private var snapshot: AccessibilityFieldSnapshot?

    func store(_ snapshot: AccessibilityFieldSnapshot?) {
        lock.lock()
        self.snapshot = snapshot
        lock.unlock()
    }

    func load() -> AccessibilityFieldSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }
}

final class PendingPasteCapture {
    private let application: NSRunningApplication
    private let before: AccessibilityFieldSnapshot
    private let insertedText: String
    private(set) var lastConfirmationFailure = "not-checked"

    private init(
        application: NSRunningApplication,
        before: AccessibilityFieldSnapshot,
        insertedText: String
    ) {
        self.application = application
        self.before = before
        self.insertedText = insertedText
    }

    static func focusedTarget(in application: NSRunningApplication) -> AccessibilityTargetIdentity? {
        guard !Thread.isMainThread else { return nil }
        if let target = AccessibilityFieldSnapshot.read(from: application, totalTimeout: 0.05)?.target {
            return target
        }
        guard PasteService.requiresVerifiedTarget(for: application.bundleIdentifier),
              AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier
        else { return nil }
        // A cold Electron renderer may not have exposed its editable field yet.
        let app = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.025)
        let originalWindow = AccessibilityFieldSnapshot.copyElementAttribute(
            kAXFocusedWindowAttribute as CFString, from: app, deadline: Date().addingTimeInterval(0.025)
        )
        guard AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
        else { return nil }
        for _ in 0..<5 {
            Thread.sleep(forTimeInterval: 0.045)
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else { return nil }
            if let target = AccessibilityFieldSnapshot.read(from: application, totalTimeout: 0.05)?.target {
                guard originalWindow.map({ CFEqual($0, target.window) }) ?? true else { return nil }
                return target
            }
        }
        return nil
    }

    func matches(_ expected: AccessibilityTargetIdentity) -> Bool {
        before.target.matches(expected)
    }

    static func capture(
        application: NSRunningApplication,
        insertedText: String
    ) -> PendingPasteCapture? {
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = SnapshotResultBox()
        DispatchQueue.global(qos: .userInitiated).async {
            let captured = AccessibilityFieldSnapshot.read(
                from: application,
                totalTimeout: 0.025,
                identifyEditor: true
            )
            resultBox.store(captured)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 0.025) == .success,
              let captured = resultBox.load() else {
            return nil
        }
        return PendingPasteCapture(application: application, before: captured, insertedText: insertedText)
    }

    /// Use the application's own paste action so the editor receives its normal paste command.
    func performNativePasteIfUnchanged(_ command: NativePasteCommand) -> NativePasteCommandResult {
        guard command.pid == application.processIdentifier,
              let current = AccessibilityFieldSnapshot.read(from: application, totalTimeout: 0.025),
              before.target.matches(current.target),
              before.text.utf16.elementsEqual(current.text.utf16),
              before.selectedRange == current.selectedRange,
              current.markedTextStatus != .present else { return .targetChanged }
        return command.perform()
    }

    func confirm() -> PasteCaptureConfirmation? {
        guard !Thread.isMainThread else {
            lastConfirmationFailure = "main-thread-read"
            return nil
        }
        guard let after = AccessibilityFieldSnapshot.read(from: application, totalTimeout: 0.05) else {
            lastConfirmationFailure = "focused-field-unavailable"
            return nil
        }
        guard before.target.matches(after.target) else {
            lastConfirmationFailure = "target-changed"
            return nil
        }

        guard let region = AnchoredTextRegion.confirmed(
            before: before.textSnapshot,
            after: after.textSnapshot,
            insertedText: insertedText,
            sameTarget: true,
            allowSelectionWithinInsertedText: true,
            isStructuralEmptyParagraph: before.isProseMirrorStructuralEmpty
        ) else {
            lastConfirmationFailure = "text-or-selection-mismatch beforeUTF16=\(before.text.utf16.count) insertedUTF16=\((insertedText as NSString).length) afterUTF16=\(after.text.utf16.count) selection=\(after.selectedRange.location),\(after.selectedRange.length)"
            return nil
        }

        let insertionEnd = region.prefix.utf16.count + region.originalText.utf16.count
        let deliveryConfirmed = !PasteService.requiresVerifiedTarget(for: application.bundleIdentifier)
            || after.target.hasVisibleInsertion(endingAt: insertionEnd)
        lastConfirmationFailure = deliveryConfirmed ? "confirmed"
            : "visible-range-or-display-unavailable insertionEnd=\(insertionEnd) selection=\(after.selectedRange.location),\(after.selectedRange.length)"

        return PasteCaptureConfirmation(
            learningAnchor: PostPasteCaptureAnchor(application: application, target: before, region: region),
            deliveryConfirmed: deliveryConfirmed
        )
    }
}

struct PasteCaptureConfirmation {
    let learningAnchor: PostPasteCaptureAnchor
    let deliveryConfirmed: Bool
}

final class PostPasteCaptureAnchor {
    private let application: NSRunningApplication
    private let target: AccessibilityFieldSnapshot
    private let region: AnchoredTextRegion
    private let pinyinWitness: PinyinCommitWitness

    var processIdentifier: pid_t { target.target.processIdentifier }

    func observeChanges(_ callback: @escaping () -> Void) -> AccessibilityObservationToken? {
        AccessibilityObservationToken(target: target.target, callback: callback)
    }

    func isCurrentlyFocused() -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier
            && target.target.focusedElementIsDifferent() == false
    }

    func isSendButton(at point: CGPoint) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier,
              AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return false }
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        let deadline = Date().addingTimeInterval(0.035)
        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(applicationElement, Float(point.x), Float(point.y), &hitElement) == .success,
              var element = hitElement else { return false }

        for _ in 0..<6 {
            guard let window = AccessibilityFieldSnapshot.copyElementAttribute(
                kAXWindowAttribute as CFString, from: element, deadline: deadline
            ), CFEqual(window, target.target.window) else { return false }
            let role = AccessibilityFieldSnapshot.copyStringAttribute(
                kAXRoleAttribute as CFString, from: element, deadline: deadline
            ) ?? ""
            let labelAttributes: [CFString] = [kAXTitleAttribute as CFString, kAXDescriptionAttribute as CFString,
                                               kAXHelpAttribute as CFString, "AXIdentifier" as CFString]
            let labels = labelAttributes
                .compactMap { AccessibilityFieldSnapshot.copyAttribute($0, from: element, deadline: deadline) as? String }
            if AccessibilityCapturePolicy.isSendButton(role: role, labels: labels) { return true }
            guard let parent = AccessibilityFieldSnapshot.copyElementAttribute(
                kAXParentAttribute as CFString, from: element, deadline: deadline
            ) else { return false }
            element = parent
        }
        return false
    }

    fileprivate init(
        application: NSRunningApplication,
        target: AccessibilityFieldSnapshot,
        region: AnchoredTextRegion
    ) {
        self.application = application
        self.target = target
        self.region = region
        self.pinyinWitness = PinyinCommitWitness()
    }

    func read(
        inputMethod: InputMethodSnapshot
    ) -> AnchoredEditObservation {
        guard !Thread.isMainThread else { return .unavailable }
        guard let current = AccessibilityFieldSnapshot.read(from: application, totalTimeout: 0.05) else {
            pinyinWitness.reset()
            return target.target.observationAfterReadFailure()
        }
        guard target.target.matches(current.target) else {
            pinyinWitness.reset()
            Log.info("Edit learning: focused field or window changed")
            return .unavailable
        }
        let shouldScanCandidates = target.isProseMirrorEditor
            && inputMethod.sourceID == PinyinCommitWitness.inputSourceID
            && current.markedTextStatus == .unavailable
            && pinyinWitness.needsCandidateScan(text: current.text, selection: current.selectedRange)
            && region.candidate(in: current.text, selectedRange: current.selectedRange).map {
                !$0.utf16.elementsEqual(region.originalText.utf16)
            } == true
        let candidateScan = shouldScanCandidates
            ? PinyinCandidateScanner.scan(processIdentifier: application.processIdentifier)
            : .unavailable
        if let witnessed = pinyinWitness.observe(
            text: current.text,
            selection: current.selectedRange,
            markedTextStatus: current.markedTextStatus,
            inputSourceID: inputMethod.sourceID,
            targetIsProseMirror: target.isProseMirrorEditor,
            candidateScan: candidateScan,
            anchoredText: { [region] text, selection in region.candidate(in: text, selectedRange: selection) }
        ) {
            return witnessed
        }
        let observation = region.observation(
            in: current.text,
            selectedRange: current.selectedRange,
            markedTextStatus: current.markedTextStatus,
            isNonDirectInputMethod: inputMethod.isNonDirect
        )
        if observation == .unavailable {
            Log.info("Edit learning: insertion boundaries or caret no longer match")
        }
        return observation
    }

    func readForMonitoring(inputMethod: InputMethodSnapshot,
                           onFocusLoss: (() -> Void)? = nil) -> AnchoredEditObservation {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != processIdentifier {
            onFocusLoss?()
            return readBound(inputMethod: inputMethod)
        }
        let current = read(inputMethod: inputMethod)
        guard current == .unavailable else { return current }
        guard target.target.focusedElementIsDifferent() == true else { return current }
        onFocusLoss?()
        return readBound(inputMethod: inputMethod)
    }

    /// AX value notifications arrive only for the stored element. When it still
    /// has focus, snapshot its committed value synchronously before Return clears it.
    func readForFieldChange(inputMethod: InputMethodSnapshot) -> AnchoredEditObservation {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier else {
            return .temporarilyUnavailable
        }
        guard let current = AccessibilityFieldSnapshot.read(from: application, totalTimeout: 0.05) else {
            return .temporarilyUnavailable
        }
        guard target.target.matches(current.target) else {
            return .temporarilyUnavailable
        }
        if current.markedTextStatus == .unavailable && inputMethod.isNonDirect { return .composing }
        return region.observation(in: current.text, selectedRange: current.selectedRange,
                                  markedTextStatus: current.markedTextStatus,
                                  isNonDirectInputMethod: inputMethod.isNonDirect)
    }

    /// Keeps observing the originally verified element after its app loses focus.
    func readBound(inputMethod: InputMethodSnapshot) -> AnchoredEditObservation {
        guard !Thread.isMainThread, AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              NSRunningApplication(processIdentifier: target.target.processIdentifier)?.isTerminated == false else {
            return .unavailable
        }
        let deadline = Date().addingTimeInterval(0.08)
        let element = target.target.element
        guard let currentWindow = AccessibilityFieldSnapshot.copyElementAttribute(
            kAXWindowAttribute as CFString, from: element, deadline: deadline
        ), CFEqual(currentWindow, target.target.window),
        let role = AccessibilityFieldSnapshot.copyStringAttribute(
            kAXRoleAttribute as CFString, from: element, deadline: deadline
        ),
        role != "AXSecureTextField",
        AccessibilityFieldSnapshot.copyStringAttribute(kAXSubroleAttribute as CFString, from: element, deadline: deadline) != "AXSecureTextField",
        (AccessibilityFieldSnapshot.copyAttribute("AXProtectedContent" as CFString, from: element, deadline: deadline) as? Bool) != true,
        let value = AccessibilityFieldSnapshot.copyAttribute(
            kAXValueAttribute as CFString, from: element, deadline: deadline
        ) as? String,
        let selected = AccessibilityFieldSnapshot.copyAXValueAttribute(
            kAXSelectedTextRangeAttribute as CFString, from: element, deadline: deadline
        ) else { return .temporarilyUnavailable }

        var range = CFRange()
        guard AXValueGetValue(selected, .cfRange, &range), range.location >= 0, range.length >= 0 else {
            return .temporarilyUnavailable
        }
        let selectedRange = NSRange(location: range.location, length: range.length)
        guard AnchoredTextRegion.isValidUTF16Range(selectedRange, in: value) else { return .temporarilyUnavailable }

        let markedValue = AccessibilityFieldSnapshot.copyAXValueAttribute(
            "AXTextInputMarkedRange" as CFString, from: element, deadline: deadline
        ) ?? AccessibilityFieldSnapshot.copyAXValueAttribute("AXMarkedTextRange" as CFString, from: element, deadline: deadline)
        var markedRange = CFRange()
        let markedStatus: MarkedTextStatus
        if let markedValue, AXValueGetValue(markedValue, .cfRange, &markedRange), markedRange.length >= 0 {
            markedStatus = markedRange.length > 0 ? .present : .absent
        } else {
            markedStatus = .unavailable
        }
        let shouldScanCandidates = target.isProseMirrorEditor
            && inputMethod.sourceID == PinyinCommitWitness.inputSourceID
            && markedStatus == .unavailable
            && pinyinWitness.needsCandidateScan(text: value, selection: selectedRange)
            && region.candidate(in: value, selectedRange: selectedRange).map {
                !$0.utf16.elementsEqual(region.originalText.utf16)
            } == true
        let candidateScan = shouldScanCandidates
            ? PinyinCandidateScanner.scan(processIdentifier: processIdentifier)
            : .unavailable
        if let witnessed = pinyinWitness.observe(
            text: value,
            selection: selectedRange,
            markedTextStatus: markedStatus,
            inputSourceID: inputMethod.sourceID,
            targetIsProseMirror: target.isProseMirrorEditor,
            candidateScan: candidateScan,
            anchoredText: { [region] text, selection in region.candidate(in: text, selectedRange: selection) }
        ) {
            return witnessed
        }
        return region.observation(in: value, selectedRange: selectedRange,
                                 markedTextStatus: markedStatus,
                                 isNonDirectInputMethod: inputMethod.isNonDirect)
    }
}

final class AccessibilityObservationToken {
    private let observer: AXObserver
    private let target: AccessibilityTargetIdentity
    private let callback: () -> Void

    fileprivate init?(target: AccessibilityTargetIdentity, callback: @escaping () -> Void) {
        self.target = target
        self.callback = callback
        var createdObserver: AXObserver?
        let creation = AXObserverCreate(target.processIdentifier, { _, _, _, context in
            guard let context else { return }
            Unmanaged<AccessibilityObservationToken>.fromOpaque(context)
                .takeUnretainedValue().callback()
        }, &createdObserver)
        guard creation == .success, let createdObserver else { return nil }
        self.observer = createdObserver
        let context = Unmanaged.passUnretained(self).toOpaque()
        let valueStatus = AXObserverAddNotification(
            createdObserver, target.element, kAXValueChangedNotification as CFString, context
        )
        let selectionStatus = AXObserverAddNotification(
            createdObserver, target.element, kAXSelectedTextChangedNotification as CFString, context
        )
        guard valueStatus == .success || selectionStatus == .success else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(createdObserver), .commonModes)
    }

    deinit {
        AXObserverRemoveNotification(observer, target.element, kAXValueChangedNotification as CFString)
        AXObserverRemoveNotification(observer, target.element, kAXSelectedTextChangedNotification as CFString)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
}

enum TypeFishInputMethodState {
    static func snapshotOnMainThread() -> InputMethodSnapshot {
        guard Thread.isMainThread,
              let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return InputMethodSnapshot(isNonDirect: true, sourceID: nil)
        }
        let sourceTypePointer = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceType)
        let sourceType = sourceTypePointer.map {
            Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String
        }
        let sourceIDPointer = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID)
        let sourceID = sourceIDPointer.map {
            Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String
        }
        return InputMethodSnapshot(
            isNonDirect: sourceType != (kTISTypeKeyboardLayout as String),
            sourceID: sourceID
        )
    }

}

enum AccessibilityCapturePolicy {
    static func isSendButton(role: String, labels: [String]) -> Bool {
        guard role == "AXButton" else { return false }
        return labels.contains { label in
            let value = label.lowercased().filter { $0.isLetter || $0.isNumber }
            return ["send", "sendmessage", "sendprompt", "sendchat", "submit", "submitmessage",
                    "composersubmitbutton", "发送", "发送消息", "发消息", "提交", "提交消息"]
                .contains(value)
        }
    }

    static func includesInsertedCharacter(endingAt caret: Int, visibleRange: CFRange) -> Bool {
        guard visibleRange.location >= 0, visibleRange.length >= 0,
              caret > visibleRange.location else { return false }
        return caret - visibleRange.location <= visibleRange.length
    }

    static func isDisplayedPlaceholder(value: String, title: String, selection: NSRange,
                                       editorClasses: [String], childClasses: [String]) -> Bool {
        guard selection == NSRange(location: 0, length: 0), !title.isEmpty,
              editorClasses.contains("ProseMirror"), childClasses.contains("placeholder") else { return false }
        return value.trimmingCharacters(in: .whitespacesAndNewlines) == title
    }

    static func isStructuralEmptyProseMirrorParagraph(
        value: String,
        selection: NSRange,
        markedTextStatus: MarkedTextStatus,
        editorRole: String,
        editorClasses: [String],
        childCount: Int,
        childRole: String?,
        childValue: String?,
        childTitle: String?,
        grandchildCount: Int?
    ) -> Bool {
        editorRole == "AXTextArea"
            && editorClasses.contains("ProseMirror")
            && value.utf16.elementsEqual("\n".utf16)
            && selection == NSRange(location: 0, length: 0)
            && markedTextStatus != .present
            && childCount == 1
            && childRole == "AXGroup"
            && childValue == ""
            && childTitle == ""
            && grandchildCount == 0
    }

    static func isSecureInput(
        role: String,
        subrole: String?,
        protectedContent: Bool,
        secureEventInputEnabled: Bool
    ) -> Bool {
        secureEventInputEnabled
            || role == "AXSecureTextField"
            || subrole == "AXSecureTextField"
            || protectedContent
    }
}

private extension AccessibilityFieldSnapshot {
    static func read(
        from application: NSRunningApplication,
        totalTimeout: TimeInterval = 0.05,
        identifyEditor: Bool = false
    ) -> AccessibilityFieldSnapshot? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else {
            return nil
        }

        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return nil }

        let deadline = Date().addingTimeInterval(totalTimeout)
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let focusedElement = copyElementAttribute(
                kAXFocusedUIElementAttribute as CFString,
                from: appElement,
                deadline: deadline
              ),
              let window = copyElementAttribute(kAXWindowAttribute as CFString, from: focusedElement, deadline: deadline),
              let role = copyStringAttribute(kAXRoleAttribute as CFString, from: focusedElement, deadline: deadline),
              isSupportedEditableRole(role, element: focusedElement, deadline: deadline),
              !isSecureElement(focusedElement, role: role, deadline: deadline),
              let textValue = copyAttribute(kAXValueAttribute as CFString, from: focusedElement, deadline: deadline) else {
            return nil
        }

        guard let text = textValue as? String else { return nil }
        guard let selectedRangeValue = copyAXValueAttribute(
            kAXSelectedTextRangeAttribute as CFString,
            from: focusedElement,
            deadline: deadline
        ) else {
            return nil
        }
        var selectedRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(selectedRangeValue, .cfRange, &selectedRange),
              AnchoredTextRegion.isValidUTF16Range(
                NSRange(location: selectedRange.location, length: selectedRange.length),
                in: text
              ) else {
            return nil
        }

        // AppKit exposes AXTextInputMarkedRange on macOS. A zero-length range
        // at the caret denotes a committed value. Some editors expose the alternate name.
        let markedValue = copyAXValueAttribute("AXTextInputMarkedRange" as CFString, from: focusedElement, deadline: deadline)
            ?? copyAXValueAttribute("AXMarkedTextRange" as CFString, from: focusedElement, deadline: deadline)
        var markedTextStatus = MarkedTextStatus.unavailable
        var markedRange = CFRange()
        if let markedValue, AXValueGetValue(markedValue, .cfRange, &markedRange),
           markedRange.length >= 0 {
            markedTextStatus = markedRange.length > 0 ? .present : .absent
        }

        let selection = NSRange(location: selectedRange.location, length: selectedRange.length)
        var editableText = text
        let needsEditorClasses = identifyEditor
            || (selection == NSRange(location: 0, length: 0) && !text.isEmpty)
        let editorClasses = needsEditorClasses
            ? (copyAttribute("AXDOMClassList" as CFString, from: focusedElement, deadline: deadline) as? [String] ?? [])
            : []
        let isProseMirrorEditor = role == "AXTextArea" && editorClasses.contains("ProseMirror")
        var isProseMirrorStructuralEmpty = false
        if isProseMirrorEditor,
           text.utf16.elementsEqual("\n".utf16), selection == NSRange(location: 0, length: 0),
           let children = copyAttribute(kAXChildrenAttribute as CFString, from: focusedElement, deadline: deadline) as? [AXUIElement],
           children.count == 1 {
            let child = children[0]
            let childRole = copyStringAttribute(kAXRoleAttribute as CFString, from: child, deadline: deadline)
            let childValue = copyStringAttribute(kAXValueAttribute as CFString, from: child, deadline: deadline)
            let childTitle = copyStringAttribute(kAXTitleAttribute as CFString, from: child, deadline: deadline)
            let grandchildren = copyAttribute(kAXChildrenAttribute as CFString, from: child, deadline: deadline) as? [AXUIElement]
            isProseMirrorStructuralEmpty = AccessibilityCapturePolicy.isStructuralEmptyProseMirrorParagraph(
                value: text,
                selection: selection,
                markedTextStatus: markedTextStatus,
                editorRole: role,
                editorClasses: editorClasses,
                childCount: children.count,
                childRole: childRole,
                childValue: childValue,
                childTitle: childTitle,
                grandchildCount: grandchildren?.count
            )
        }
        // A blank Codex composer exposes its prompt as AXValue and as a single
        // placeholder child. The first typed character removes that child.
        if !text.isEmpty, selection == NSRange(location: 0, length: 0),
           let title = copyStringAttribute(kAXTitleAttribute as CFString, from: focusedElement, deadline: deadline),
           isProseMirrorEditor,
           let children = copyAttribute(kAXChildrenAttribute as CFString, from: focusedElement, deadline: deadline) as? [AXUIElement],
           children.count == 1,
           let classes = copyAttribute("AXDOMClassList" as CFString, from: children[0], deadline: deadline) as? [String],
           AccessibilityCapturePolicy.isDisplayedPlaceholder(value: text, title: title, selection: selection,
                                                              editorClasses: editorClasses, childClasses: classes) {
            editableText = ""
        }

        return AccessibilityFieldSnapshot(
            target: AccessibilityTargetIdentity(
                processIdentifier: application.processIdentifier,
                window: window,
                element: focusedElement
            ),
            text: editableText,
            selectedRange: selection,
            markedTextStatus: markedTextStatus,
            isProseMirrorEditor: isProseMirrorEditor,
            isProseMirrorStructuralEmpty: isProseMirrorStructuralEmpty
        )
    }

    fileprivate static func copyAttribute(
        _ attribute: CFString,
        from element: AXUIElement,
        deadline: Date
    ) -> AnyObject? {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return nil }
        AXUIElementSetMessagingTimeout(element, Float(min(remaining, 0.025)))
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value
    }

    fileprivate static func copyElementAttribute(_ attribute: CFString, from element: AXUIElement, deadline: Date) -> AXUIElement? {
        guard let value = copyAttribute(attribute, from: element, deadline: deadline) else { return nil }
        let reference = value as CFTypeRef
        guard CFGetTypeID(reference) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(reference, to: AXUIElement.self)
    }

    fileprivate static func copyAXValueAttribute(_ attribute: CFString, from element: AXUIElement, deadline: Date) -> AXValue? {
        guard let value = copyAttribute(attribute, from: element, deadline: deadline) else { return nil }
        let reference = value as CFTypeRef
        guard CFGetTypeID(reference) == AXValueGetTypeID() else { return nil }
        return unsafeBitCast(reference, to: AXValue.self)
    }

    fileprivate static func copyStringAttribute(_ attribute: CFString, from element: AXUIElement, deadline: Date) -> String? {
        copyAttribute(attribute, from: element, deadline: deadline) as? String
    }

    private static func isSupportedEditableRole(_ role: String, element: AXUIElement, deadline: Date) -> Bool {
        let standardRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"]
        if standardRoles.contains(role) { return true }
        guard role == "AXWebArea",
              let editable = copyAttribute("AXEditable" as CFString, from: element, deadline: deadline) as? Bool else {
            return false
        }
        return editable
    }

    private static func isSecureElement(_ element: AXUIElement, role: String, deadline: Date) -> Bool {
        let subrole = copyStringAttribute(kAXSubroleAttribute as CFString, from: element, deadline: deadline)
        let isProtected = (copyAttribute("AXProtectedContent" as CFString, from: element, deadline: deadline) as? Bool) == true
        return AccessibilityCapturePolicy.isSecureInput(
            role: role,
            subrole: subrole,
            protectedContent: isProtected,
            secureEventInputEnabled: false
        )
    }
}

struct AccessibilityTargetIdentity {
    let processIdentifier: pid_t
    let window: AXUIElement
    let element: AXUIElement

    fileprivate func hasVisibleInsertion(endingAt caret: Int) -> Bool {
        func rect(of element: AXUIElement) -> CGRect? {
            var point = CGPoint.zero, size = CGSize.zero
            let deadline = Date().addingTimeInterval(0.04)
            guard let position = AccessibilityFieldSnapshot.copyAXValueAttribute(
                kAXPositionAttribute as CFString, from: element, deadline: deadline
            ), let dimensions = AccessibilityFieldSnapshot.copyAXValueAttribute(
                kAXSizeAttribute as CFString, from: element, deadline: deadline
            ), AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(dimensions, .cgSize, &size) else { return nil }
            return CGRect(origin: point, size: size)
        }
        guard let fieldRect = rect(of: element), let windowRect = rect(of: window) else { return false }
        let visibleRect = fieldRect.intersection(windowRect)
        var displays: UInt32 = 0
        guard !visibleRect.isEmpty, CGGetDisplaysWithRect(visibleRect, 0, nil, &displays) == .success,
              displays > 0 else { return false }
        guard let range = AccessibilityFieldSnapshot.copyAXValueAttribute(
            kAXVisibleCharacterRangeAttribute as CFString, from: element, deadline: Date().addingTimeInterval(0.025)
        ) else { return true }
        var visible = CFRange()
        guard AXValueGetValue(range, .cfRange, &visible), visible.location >= 0, visible.length >= 0 else { return true }
        // At least the last inserted character should be visible in a scrolling composer.
        return AccessibilityCapturePolicy.includesInsertedCharacter(endingAt: caret, visibleRange: visible)
    }

    /// A failed text read is retryable only while the original window remains active.
    /// A positively identified different field, app or window invalidates the session.
    fileprivate func observationAfterReadFailure() -> AnchoredEditObservation {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier
        else { return .unavailable }
        let app = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.025)
        var currentWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &currentWindow) == .success,
              let currentWindow, CFEqual(currentWindow, window) else { return .unavailable }
        var currentField: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &currentField)
        if status == .cannotComplete || status == .noValue { return .temporarilyUnavailable }
        guard status == .success, let currentField, CFEqual(currentField, element) else { return .unavailable }
        return .temporarilyUnavailable
    }

    func matches(_ other: AccessibilityTargetIdentity) -> Bool {
        processIdentifier == other.processIdentifier
            && CFEqual(window, other.window)
            && CFEqual(element, other.element)
    }

    fileprivate func focusedElementIsDifferent() -> Bool? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(processIdentifier)
        let deadline = Date().addingTimeInterval(0.05)
        guard let currentWindow = AccessibilityFieldSnapshot.copyElementAttribute(
            kAXFocusedWindowAttribute as CFString, from: app, deadline: deadline
        ), let currentField = AccessibilityFieldSnapshot.copyElementAttribute(
            kAXFocusedUIElementAttribute as CFString, from: app, deadline: deadline
        ) else { return nil }
        return !CFEqual(currentWindow, window) || !CFEqual(currentField, element)
    }
}
