import XCTest
import ApplicationServices
@testable import TypeFish

final class PostPasteCaptureTests: XCTestCase {
    func testBlankWebEditorRequiresAnExplicitPlaceholderChildAndCollapsedStart() {
        func isPlaceholder(_ text: String, _ children: [String], cursor: Int = 0) -> Bool {
            AccessibilityCapturePolicy.isDisplayedPlaceholder(value: text, title: "Example prompt",
                selection: NSRange(location: cursor, length: 0), editorClasses: ["ProseMirror"], childClasses: children)
        }
        XCTAssertTrue(isPlaceholder("Example prompt\n", ["placeholder"]))
        XCTAssertFalse(isPlaceholder("Example prompt", []))
        XCTAssertFalse(isPlaceholder("Actual draft", ["placeholder"]))
        XCTAssertFalse(isPlaceholder("Example prompt", ["placeholder"], cursor: 3))
    }

    func testPolishContextUsesActualUTF16CaretAndIsEmptyAtStart() {
        XCTAssertEqual(ContextReader.textBeforeSelection(in: "draft", range: NSRange(location: 0, length: 0)), "")
        XCTAssertEqual(ContextReader.textBeforeSelection(in: "🚀草稿", range: NSRange(location: 2, length: 0)), "🚀")
        XCTAssertNil(ContextReader.textBeforeSelection(in: "🚀草稿", range: NSRange(location: 1, length: 0)))
    }

    func testConfirmsExactReplacementUsingUTF16SelectionRange() {
        let original = "🚀你好，please use Cloud Code。"
        let originalNSString = original as NSString
        let selectedRange = originalNSString.range(of: "Cloud")
        let before = TextFieldSnapshot(text: original, selectedRange: selectedRange, hasMarkedText: false)
        let expected = originalNSString.replacingCharacters(in: selectedRange, with: "Claude")
        let after = TextFieldSnapshot(
            text: expected,
            selectedRange: NSRange(location: selectedRange.location + ("Claude" as NSString).length, length: 0),
            hasMarkedText: false
        )

        let region = AnchoredTextRegion.confirmed(
            before: before,
            after: after,
            insertedText: "Claude",
            sameTarget: true
        )

        XCTAssertEqual(region?.prefix, "🚀你好，please use ")
        XCTAssertEqual(region?.suffix, " Code。")
        XCTAssertEqual(region?.candidate(in: "🚀你好，please use Claude Code。"), "Claude")
    }

    func testConfirmsInsertionAtCaretAndSelectionReplacement() {
        let insertionBefore = TextFieldSnapshot(
            text: "before  after",
            selectedRange: NSRange(location: 7, length: 0),
            hasMarkedText: false
        )
        let insertionAfter = TextFieldSnapshot(
            text: "before word after",
            selectedRange: NSRange(location: 11, length: 0),
            hasMarkedText: false
        )
        let insertionRegion = AnchoredTextRegion.confirmed(
            before: insertionBefore,
            after: insertionAfter,
            insertedText: "word",
            sameTarget: true
        )
        XCTAssertEqual(insertionRegion?.prefix, "before ")
        XCTAssertEqual(insertionRegion?.suffix, " after")
        XCTAssertEqual(insertionRegion?.candidate(in: "before corrected after"), "corrected")

        let replacementBefore = TextFieldSnapshot(
            text: "before bad after",
            selectedRange: NSRange(location: 7, length: 3),
            hasMarkedText: false
        )
        let replacementAfter = TextFieldSnapshot(
            text: "before good after",
            selectedRange: NSRange(location: 11, length: 0),
            hasMarkedText: false
        )
        XCTAssertEqual(
            AnchoredTextRegion.confirmed(
                before: replacementBefore,
                after: replacementAfter,
                insertedText: "good",
                sameTarget: true
            )?.candidate(in: "before great after"),
            "great"
        )
    }

    func testRejectsDifferentTargetMarkedTextAndUnexpectedPasteResult() {
        let before = TextFieldSnapshot(
            text: "some text",
            selectedRange: NSRange(location: 5, length: 0),
            hasMarkedText: false
        )
        let after = TextFieldSnapshot(
            text: "some wordtext",
            selectedRange: NSRange(location: 9, length: 0),
            hasMarkedText: false
        )
        XCTAssertNil(AnchoredTextRegion.confirmed(before: before, after: after, insertedText: "word", sameTarget: false))

        let composing = TextFieldSnapshot(
            text: "some wordtext",
            selectedRange: NSRange(location: 9, length: 0),
            hasMarkedText: true
        )
        XCTAssertNil(AnchoredTextRegion.confirmed(before: before, after: composing, insertedText: "word", sameTarget: true))
        XCTAssertNil(AnchoredTextRegion.confirmed(before: before, after: before, insertedText: "word", sameTarget: true))
    }

    func testCandidateUsesFixedAnchorsAndReportsCompositionOrClear() {
        let region = AnchoredTextRegion(prefix: "left ", suffix: " right", originalText: "wrong")
        XCTAssertEqual(region.observation(in: "left corrected right", selectedRange: NSRange(location: 10, length: 0), markedTextStatus: .absent, isNonDirectInputMethod: false), .text("corrected"))
        XCTAssertEqual(region.observation(in: "left composing right", selectedRange: NSRange(location: 10, length: 0), markedTextStatus: .present, isNonDirectInputMethod: false), .composing)
        XCTAssertEqual(region.observation(in: "", selectedRange: NSRange(location: 0, length: 0), markedTextStatus: .absent, isNonDirectInputMethod: false), .cleared)
        XCTAssertEqual(region.observation(in: "left corrected right left other right", selectedRange: NSRange(location: 10, length: 0), markedTextStatus: .absent, isNonDirectInputMethod: false), .text("corrected right left other"))
    }

    func testFixedAnchorBoundariesAllowDuplicateTextInsideField() {
        let region = AnchoredTextRegion(prefix: "we said ", suffix: " yesterday", originalText: "wrong")
        XCTAssertEqual(region.candidate(in: "we said we said corrected yesterday"), "we said corrected")
        XCTAssertNil(region.candidate(in: "extra we said corrected yesterday"))
    }

    func testUnknownMarkedRangeDefersNonDirectInputAndAllowsDirectInput() {
        let region = AnchoredTextRegion(prefix: "before ", suffix: " after", originalText: "wrong")
        XCTAssertEqual(
            region.observation(in: "before 拼音 after", selectedRange: NSRange(location: 9, length: 0), markedTextStatus: .unavailable, isNonDirectInputMethod: true),
            .composing
        )
        XCTAssertEqual(
            region.observation(
                in: "before 拼音 after",
                selectedRange: NSRange(location: 9, length: 0),
                markedTextStatus: .unavailable,
                isNonDirectInputMethod: false
            ),
            .text("拼音")
        )
        XCTAssertEqual(
            region.observation(in: "before value after", selectedRange: NSRange(location: 12, length: 0), markedTextStatus: .unavailable, isNonDirectInputMethod: false),
            .text("value")
        )
    }

    func testEmptyFieldCanBeConfirmedAndNoOpReplacementCannot() {
        let emptyBefore = TextFieldSnapshot(text: "", selectedRange: NSRange(location: 0, length: 0), hasMarkedText: false)
        let emptyAfter = TextFieldSnapshot(text: "inserted", selectedRange: NSRange(location: 8, length: 0), hasMarkedText: false)
        XCTAssertEqual(
            AnchoredTextRegion.confirmed(before: emptyBefore, after: emptyAfter, insertedText: "inserted", sameTarget: true)?.candidate(in: "corrected"),
            "corrected"
        )

        let selectedBefore = TextFieldSnapshot(text: "same", selectedRange: NSRange(location: 0, length: 4), hasMarkedText: false)
        let noOpAfter = TextFieldSnapshot(text: "same", selectedRange: NSRange(location: 4, length: 0), hasMarkedText: false)
        XCTAssertNil(AnchoredTextRegion.confirmed(before: selectedBefore, after: noOpAfter, insertedText: "same", sameTarget: true))
        let wrongCaret = TextFieldSnapshot(text: "same", selectedRange: NSRange(location: 0, length: 0), hasMarkedText: false)
        XCTAssertNil(AnchoredTextRegion.confirmed(before: selectedBefore, after: wrongCaret, insertedText: "same", sameTarget: true))
    }

    func testAXSnapshotRequiresStringButAllowsEmptyString() {
        XCTAssertNotNil(TextFieldSnapshot(axValue: "", selectedRange: NSRange(location: 0, length: 0), markedTextStatus: .unavailable))
        XCTAssertNil(TextFieldSnapshot(axValue: NSNumber(value: 7), selectedRange: NSRange(location: 0, length: 0), markedTextStatus: .absent))
        XCTAssertNil(TextFieldSnapshot(axValue: nil, selectedRange: NSRange(location: 0, length: 0), markedTextStatus: .absent))
    }

    func testSecureInputAndPasteboardHelpers() {
        XCTAssertTrue(AccessibilityCapturePolicy.isSecureInput(
            role: "AXSecureTextField",
            subrole: nil,
            protectedContent: false,
            secureEventInputEnabled: false
        ))
        XCTAssertTrue(AccessibilityCapturePolicy.isSecureInput(
            role: "AXTextField",
            subrole: "AXSecureTextField",
            protectedContent: false,
            secureEventInputEnabled: false
        ))
        XCTAssertTrue(AccessibilityCapturePolicy.isSecureInput(
            role: "AXTextField",
            subrole: nil,
            protectedContent: false,
            secureEventInputEnabled: true
        ))
        XCTAssertFalse(AccessibilityCapturePolicy.isSecureInput(
            role: "AXTextField",
            subrole: nil,
            protectedContent: false,
            secureEventInputEnabled: false
        ))
        XCTAssertTrue(PasteService.shouldActivateSavedApp(frontmostPID: nil, targetPID: 10))
        XCTAssertTrue(PasteService.shouldActivateSavedApp(frontmostPID: 9, targetPID: 10))
        XCTAssertFalse(PasteService.shouldActivateSavedApp(frontmostPID: 10, targetPID: 10))
        XCTAssertTrue(PasteService.shouldRestorePasteboard(currentChangeCount: 4, writtenChangeCount: 4))
        XCTAssertFalse(PasteService.shouldRestorePasteboard(currentChangeCount: 5, writtenChangeCount: 4))
    }

    func testCandidateSupportsFieldWithNoContextAroundInsertion() {
        let wholeField = AnchoredTextRegion(prefix: "", suffix: "", originalText: "wrong")
        XCTAssertEqual(wholeField.candidate(in: "corrected"), "corrected")
    }

    func testCandidateRequiresCaretOrSelectionInsideAnchoredSpan() {
        let region = AnchoredTextRegion(prefix: "left ", suffix: " right", originalText: "wrong")
        let field = "left corrected right"
        XCTAssertEqual(region.candidate(in: field, selectedRange: NSRange(location: 10, length: 0)), "corrected")
        XCTAssertEqual(region.candidate(in: field, selectedRange: NSRange(location: 7, length: 3)), "corrected")
        XCTAssertNil(region.candidate(in: field, selectedRange: NSRange(location: 0, length: 0)))
        XCTAssertNil(region.candidate(in: field, selectedRange: NSRange(location: NSNotFound, length: 0)))
        XCTAssertNil(region.candidate(in: field, selectedRange: NSRange(location: 19, length: 4)))
    }

    func testUTF16RangesCannotSplitSurrogatePairs() {
        XCTAssertFalse(AnchoredTextRegion.isValidUTF16Range(NSRange(location: 1, length: 0), in: "🚀 text"))
        XCTAssertFalse(AnchoredTextRegion.isValidUTF16Range(NSRange(location: 0, length: 1), in: "🚀 text"))
        XCTAssertTrue(AnchoredTextRegion.isValidUTF16Range(NSRange(location: 0, length: 2), in: "🚀 text"))

        let before = TextFieldSnapshot(text: "🚀x", selectedRange: NSRange(location: 1, length: 0), hasMarkedText: false)
        let after = TextFieldSnapshot(text: "🚀wordx", selectedRange: NSRange(location: 6, length: 0), hasMarkedText: false)
        XCTAssertNil(AnchoredTextRegion.confirmed(before: before, after: after, insertedText: "word", sameTarget: true))
    }

    func testAccessibilityTargetRequiresSameAppWindowAndFocusedElement() {
        let pid = getpid()
        let appElement = AXUIElementCreateApplication(pid)
        let otherElement = AXUIElementCreateSystemWide()
        let baseline = AccessibilityTargetIdentity(
            processIdentifier: pid,
            window: appElement,
            element: appElement
        )
        let same = AccessibilityTargetIdentity(
            processIdentifier: pid,
            window: AXUIElementCreateApplication(pid),
            element: AXUIElementCreateApplication(pid)
        )
        let changedWindow = AccessibilityTargetIdentity(
            processIdentifier: pid,
            window: otherElement,
            element: appElement
        )
        let changedElement = AccessibilityTargetIdentity(
            processIdentifier: pid,
            window: appElement,
            element: otherElement
        )
        let changedApplication = AccessibilityTargetIdentity(
            processIdentifier: pid + 1,
            window: appElement,
            element: appElement
        )

        XCTAssertTrue(baseline.matches(same))
        XCTAssertFalse(baseline.matches(changedWindow))
        XCTAssertFalse(baseline.matches(changedElement))
        XCTAssertFalse(baseline.matches(changedApplication))
    }
}
