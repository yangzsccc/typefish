import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum AnchoredEditObservation: Equatable {
    case text(String)
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
        sameTarget: Bool
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
        guard !exactlyMatches(before.text, after.text),
              exactlyMatches(after.text, expectedText) else {
            return nil
        }

        let insertedRange = NSRange(
            location: before.selectedRange.location,
            length: (insertedText as NSString).length
        )
        guard after.selectedRange.location == NSMaxRange(insertedRange),
              after.selectedRange.length == 0 else {
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

    private init(
        application: NSRunningApplication,
        before: AccessibilityFieldSnapshot,
        insertedText: String
    ) {
        self.application = application
        self.before = before
        self.insertedText = insertedText
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
                totalTimeout: 0.025
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

    func confirm() -> PostPasteCaptureAnchor? {
        guard !Thread.isMainThread else { return nil }
        guard let after = AccessibilityFieldSnapshot.read(from: application, totalTimeout: 0.05),
              before.target.matches(after.target),
              let region = AnchoredTextRegion.confirmed(
                before: before.textSnapshot,
                after: after.textSnapshot,
                insertedText: insertedText,
                sameTarget: true
              ) else {
            return nil
        }

        return PostPasteCaptureAnchor(application: application, target: before, region: region)
    }
}

final class PostPasteCaptureAnchor {
    private let application: NSRunningApplication
    private let target: AccessibilityFieldSnapshot
    private let region: AnchoredTextRegion

    fileprivate init(
        application: NSRunningApplication,
        target: AccessibilityFieldSnapshot,
        region: AnchoredTextRegion
    ) {
        self.application = application
        self.target = target
        self.region = region
    }

    func read(
        isNonDirectInputMethod: Bool
    ) -> AnchoredEditObservation {
        guard !Thread.isMainThread else { return .unavailable }
        guard let current = AccessibilityFieldSnapshot.read(from: application, totalTimeout: 0.05),
              target.target.matches(current.target) else {
            return .unavailable
        }
        return region.observation(
            in: current.text,
            selectedRange: current.selectedRange,
            markedTextStatus: current.markedTextStatus,
            isNonDirectInputMethod: isNonDirectInputMethod
        )
    }
}

enum TypeFishInputMethodState {
    static func isNonDirectOnMainThread() -> Bool {
        guard Thread.isMainThread else { return true }
        guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let sourceTypePointer = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceType) else {
            return true
        }
        let sourceType = Unmanaged<CFString>.fromOpaque(sourceTypePointer).takeUnretainedValue() as String
        return sourceType != (kTISTypeKeyboardLayout as String)
    }
}

enum AccessibilityCapturePolicy {
    static func isDisplayedPlaceholder(value: String, title: String, selection: NSRange,
                                       editorClasses: [String], childClasses: [String]) -> Bool {
        guard selection == NSRange(location: 0, length: 0), !title.isEmpty,
              editorClasses.contains("ProseMirror"), childClasses.contains("placeholder") else { return false }
        return value.trimmingCharacters(in: .whitespacesAndNewlines) == title
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
        totalTimeout: TimeInterval = 0.05
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
        // A blank Codex composer exposes its prompt as AXValue and as a single
        // placeholder child. The first typed character removes that child.
        if !text.isEmpty, selection == NSRange(location: 0, length: 0),
           let title = copyStringAttribute(kAXTitleAttribute as CFString, from: focusedElement, deadline: deadline),
           let editorClasses = copyAttribute("AXDOMClassList" as CFString, from: focusedElement, deadline: deadline) as? [String],
           editorClasses.contains("ProseMirror"),
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
            markedTextStatus: markedTextStatus
        )
    }

    private static func copyAttribute(
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

    private static func copyElementAttribute(_ attribute: CFString, from element: AXUIElement, deadline: Date) -> AXUIElement? {
        guard let value = copyAttribute(attribute, from: element, deadline: deadline) else { return nil }
        let reference = value as CFTypeRef
        guard CFGetTypeID(reference) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(reference, to: AXUIElement.self)
    }

    private static func copyAXValueAttribute(_ attribute: CFString, from element: AXUIElement, deadline: Date) -> AXValue? {
        guard let value = copyAttribute(attribute, from: element, deadline: deadline) else { return nil }
        let reference = value as CFTypeRef
        guard CFGetTypeID(reference) == AXValueGetTypeID() else { return nil }
        return unsafeBitCast(reference, to: AXValue.self)
    }

    private static func copyStringAttribute(_ attribute: CFString, from element: AXUIElement, deadline: Date) -> String? {
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

    func matches(_ other: AccessibilityTargetIdentity) -> Bool {
        processIdentifier == other.processIdentifier
            && CFEqual(window, other.window)
            && CFEqual(element, other.element)
    }
}
