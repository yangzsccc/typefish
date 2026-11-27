import AppKit
import ApplicationServices

struct InputMethodSnapshot: Equatable {
    let isNonDirect: Bool
    let sourceID: String?
}

struct PinyinCandidateScan: Equatable {
    enum Status: Equatable { case unavailable, absent, visible }
    let status: Status
    let candidates: Set<String>

    static let unavailable = PinyinCandidateScan(status: .unavailable, candidates: [])
    static let absent = PinyinCandidateScan(status: .absent, candidates: [])
}

/// Confirms a Pinyin commit only from a previously observed native candidate
/// list and its exact replacement in the same anchored editor field.
final class PinyinCommitWitness {
    static let inputSourceID = "com.apple.inputmethod.SCIM.ITABC"
    static let evidenceGrace: TimeInterval = 0.5

    private struct CandidateEvidence {
        let prefix: String
        let suffix: String
        let provisionalText: String
        let caretLocation: Int
        let candidates: Set<String>
        let observedAt: TimeInterval
    }

    private struct HeldCommit {
        let exactFieldText: String
        let anchorText: String
        let observedAt: TimeInterval
    }

    private var evidence: CandidateEvidence?
    private var heldCommit: HeldCommit?

    func reset() {
        evidence = nil
        heldCommit = nil
    }

    var hasPendingEvidence: Bool { evidence != nil }

    func needsCandidateScan(text: String, selection: NSRange) -> Bool {
        evidence != nil || heldCommit != nil || Self.phoneticSpan(in: text, selection: selection) != nil
    }

    /// Returns nil when ordinary marked-range/direct-input behavior should decide.
    func observe(
        text: String,
        selection: NSRange,
        markedTextStatus: MarkedTextStatus,
        inputSourceID: String?,
        targetIsProseMirror: Bool,
        candidateScan: PinyinCandidateScan,
        monotonicNow: TimeInterval = ProcessInfo.processInfo.systemUptime,
        anchoredText: (String, NSRange) -> String?
    ) -> AnchoredEditObservation? {
        guard targetIsProseMirror,
              inputSourceID == Self.inputSourceID,
              markedTextStatus == .unavailable,
              AnchoredTextRegion.isValidUTF16Range(selection, in: text) else {
            reset()
            return nil
        }

        if let heldCommit {
            if candidateScan.status == .absent,
               Self.exact(text, heldCommit.exactFieldText),
               let currentAnchor = anchoredText(text, selection), Self.exact(currentAnchor, heldCommit.anchorText) {
                return .text(heldCommit.anchorText)
            }
            if candidateScan.status == .unavailable,
               Self.exact(text, heldCommit.exactFieldText),
               monotonicNow - heldCommit.observedAt <= Self.evidenceGrace,
               anchoredText(text, selection).map({ Self.exact($0, heldCommit.anchorText) }) == true {
                return .composing
            }
            if candidateScan.status == .visible,
               let next = Self.evidenceFor(text: text, selection: selection,
                                           candidates: candidateScan.candidates, observedAt: monotonicNow),
               anchoredText(text, selection) != nil {
                self.heldCommit = nil
                evidence = next
                return .composing
            }
            self.heldCommit = nil
            evidence = nil
            return .composing
        }

        if let evidence {
            if Self.committedCandidate(text: text, selection: selection, evidence: evidence) != nil {
                switch candidateScan.status {
                case .visible:
                    return monotonicNow - evidence.observedAt <= Self.evidenceGrace
                        ? .composing : clearEvidenceAndCompose()
                case .unavailable:
                    if monotonicNow - evidence.observedAt > Self.evidenceGrace { self.evidence = nil }
                    return .composing
                case .absent:
                    guard monotonicNow - evidence.observedAt <= Self.evidenceGrace else {
                        self.evidence = nil
                        return .composing
                    }
                    guard let anchor = anchoredText(text, selection) else {
                        self.evidence = nil
                        return .composing
                    }
                    self.evidence = nil
                    heldCommit = HeldCommit(exactFieldText: text, anchorText: anchor, observedAt: monotonicNow)
                    return .text(anchor)
                }
            }
            let sameProvisional = Self.exact(text, evidence.provisionalText)
                && selection.length == 0 && selection.location == evidence.caretLocation
            if sameProvisional {
                switch candidateScan.status {
                case .visible:
                    guard let refreshed = Self.evidenceFor(text: text, selection: selection,
                                                           candidates: candidateScan.candidates,
                                                           observedAt: monotonicNow),
                          anchoredText(text, selection) != nil else {
                        self.evidence = nil
                        return .composing
                    }
                    self.evidence = refreshed
                    return .composing
                case .unavailable, .absent:
                    guard monotonicNow - evidence.observedAt <= Self.evidenceGrace else {
                        self.evidence = nil
                        return .composing
                    }
                    self.evidence = evidence
                    return .composing
                }
            }
            if Self.exact(text, evidence.prefix + evidence.suffix) {
                self.evidence = nil // Canceled preedit restored the text around its phonetic span.
                return nil
            }
            switch candidateScan.status {
            case .visible:
                guard let replacement = Self.evidenceFor(text: text, selection: selection,
                                                         candidates: candidateScan.candidates,
                                                         observedAt: monotonicNow) else {
                    self.evidence = nil
                    return .composing
                }
                guard anchoredText(text, selection) != nil else {
                    self.evidence = nil
                    return .composing
                }
                self.evidence = replacement // Replace evidence on each new syllable; never union lists.
                return .composing
            case .unavailable:
                self.evidence = nil
                return .composing
            case .absent:
                self.evidence = nil
                return .composing
            }
        }

        switch candidateScan.status {
        case .visible:
            guard let next = Self.evidenceFor(text: text, selection: selection,
                                              candidates: candidateScan.candidates,
                                              observedAt: monotonicNow) else {
                return Self.phoneticSpan(in: text, selection: selection) == nil ? nil : .composing
            }
            guard anchoredText(text, selection) != nil else { return .composing }
            evidence = next
            return .composing
        case .unavailable:
            return Self.phoneticSpan(in: text, selection: selection) == nil ? nil : .composing
        case .absent:
            return nil
        }
    }

    private static func evidenceFor(
        text: String,
        selection: NSRange,
        candidates: Set<String>,
        observedAt: TimeInterval
    ) -> CandidateEvidence? {
        guard !candidates.isEmpty, let span = phoneticSpan(in: text, selection: selection) else { return nil }
        let value = text as NSString
        return CandidateEvidence(
            prefix: value.substring(to: span.location),
            suffix: value.substring(from: span.location + span.length),
            provisionalText: text,
            caretLocation: selection.location,
            candidates: candidates,
            observedAt: observedAt
        )
    }

    private static func phoneticSpan(in text: String, selection: NSRange) -> (location: Int, length: Int)? {
        guard selection.length == 0,
              AnchoredTextRegion.isValidUTF16Range(selection, in: text),
              selection.location > 0 else { return nil }
        let value = text as NSString
        var start = selection.location
        while start > 0 {
            let unit = value.character(at: start - 1)
            guard (0x61...0x7A).contains(unit) || unit == 0x20 else { break }
            start -= 1
            guard selection.location - start <= 32 else { return nil }
        }
        let length = selection.location - start
        guard length > 0, length <= 32 else { return nil }
        let phonetic = value.substring(with: NSRange(location: start, length: length))
        let syllables = phonetic.split(separator: " ", omittingEmptySubsequences: false)
        guard syllables.count <= 6,
              syllables.allSatisfy({ !$0.isEmpty && $0.count <= 12 && $0.utf8.allSatisfy({ (0x61...0x7A).contains($0) }) }) else { return nil }
        return (start, length)
    }

    private static func committedCandidate(
        text: String,
        selection: NSRange,
        evidence: CandidateEvidence
    ) -> String? {
        let value = text as NSString
        let prefixLength = (evidence.prefix as NSString).length
        let suffixLength = (evidence.suffix as NSString).length
        guard value.length >= prefixLength + suffixLength,
              Self.exact(value.substring(to: prefixLength), evidence.prefix),
              Self.exact(value.substring(from: value.length - suffixLength), evidence.suffix) else { return nil }
        let candidateLength = value.length - prefixLength - suffixLength
        guard candidateLength > 0 else { return nil }
        let candidate = value.substring(with: NSRange(location: prefixLength, length: candidateLength))
        guard evidence.candidates.contains(where: { Self.exact($0, candidate) }), selection.length == 0,
              selection.location == prefixLength + candidateLength else { return nil }
        return candidate
    }

    private static func exact(_ lhs: String, _ rhs: String) -> Bool { lhs.utf16.elementsEqual(rhs.utf16) }

    private func clearEvidenceAndCompose() -> AnchoredEditObservation {
        evidence = nil
        return .composing
    }
}

/// Scans only the target application's own AX windows. Query work and list sizes
/// are capped so candidate inspection stays bounded and on demand.
enum PinyinCandidateScanner {
    static func scan(processIdentifier: pid_t, timeout: TimeInterval = 0.025) -> PinyinCandidateScan {
        let deadline = Date().addingTimeInterval(timeout)
        let app = AXUIElementCreateApplication(processIdentifier)
        guard let windows = array(kAXWindowsAttribute as CFString, from: app, deadline: deadline),
              windows.count <= 24 else { return .unavailable }
        for window in windows.prefix(24) {
            guard let identity = strings([kAXRoleAttribute as CFString, kAXSubroleAttribute as CFString], from: window, deadline: deadline),
                  identity.count == 2, let role = identity[0] as? String, let subrole = identity[1] as? String else { return .unavailable }
            guard role == "AXWindow", subrole == "AXDialog" else { continue }
            guard let children = array(kAXChildrenAttribute as CFString, from: window, deadline: deadline),
                  children.count <= 8 else { return .unavailable }
            for child in children.prefix(8) {
                guard let identity = strings([kAXRoleAttribute as CFString, "AXIdentifier" as CFString], from: child, deadline: deadline),
                      identity.count == 2, let childRole = identity[0] as? String else { return .unavailable }
                guard childRole == "AXList" else { continue }
                guard let identifier = identity[1] as? String else { return .unavailable }
                guard identifier == "InputMethodCandidateList" else { continue }
                guard let buttons = array(kAXVisibleChildrenAttribute as CFString, from: child, deadline: deadline) else { return .unavailable }
                var candidates = Set<String>()
                for button in buttons.prefix(16) {
                    guard let attributes = strings([kAXRoleAttribute as CFString, kAXTitleAttribute as CFString], from: button, deadline: deadline),
                          attributes.count == 2, let buttonRole = attributes[0] as? String,
                          let title = attributes[1] as? String else {
                        return candidates.isEmpty ? .unavailable : PinyinCandidateScan(status: .visible, candidates: candidates)
                    }
                    guard buttonRole == "AXButton" else { return .unavailable }
                    if Self.isHanCandidate(title) { candidates.insert(title) }
                }
                return PinyinCandidateScan(status: .visible, candidates: candidates)
            }
        }
        return .absent
    }

    private static func isHanCandidate(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 12 && text.unicodeScalars.allSatisfy {
            (0x3400...0x9FFF).contains(Int($0.value))
        }
    }

    private static func strings(_ attributes: [CFString], from element: AXUIElement, deadline: Date) -> [Any]? {
        guard let values = copyMultiple(attributes, from: element, deadline: deadline) else { return nil }
        return values
    }

    private static func array(_ attribute: CFString, from element: AXUIElement, deadline: Date) -> [AXUIElement]? {
        guard let value = copy(attribute, from: element, deadline: deadline) else { return nil }
        return value as? [AXUIElement]
    }

    private static func copy(_ attribute: CFString, from element: AXUIElement, deadline: Date) -> CFTypeRef? {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return nil }
        AXUIElementSetMessagingTimeout(element, Float(min(remaining, 0.025)))
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value
    }

    private static func copyMultiple(_ attributes: [CFString], from element: AXUIElement, deadline: Date) -> [Any]? {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return nil }
        AXUIElementSetMessagingTimeout(element, Float(min(remaining, 0.025)))
        var values: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(
            element,
            attributes as CFArray,
            [],
            &values
        )
        guard result == .success, let values else { return nil }
        return values as? [Any]
    }
}
