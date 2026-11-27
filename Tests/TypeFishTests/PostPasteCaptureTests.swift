import XCTest
import ApplicationServices
@testable import TypeFish

final class PostPasteCaptureTests: XCTestCase {
    func testSendButtonLabelMustBeAnExactSubmissionControl() {
        XCTAssertTrue(AccessibilityCapturePolicy.isSendButton(role: "AXButton", labels: ["Send"]))
        XCTAssertTrue(AccessibilityCapturePolicy.isSendButton(role: "AXButton", labels: ["Send message"]))
        XCTAssertTrue(AccessibilityCapturePolicy.isSendButton(role: "AXButton", labels: ["发送消息"]))
        XCTAssertTrue(AccessibilityCapturePolicy.isSendButton(role: "AXButton", labels: ["composer-submit-button"]))
        XCTAssertFalse(AccessibilityCapturePolicy.isSendButton(role: "AXButton", labels: ["Resend", "New chat"]))
        XCTAssertFalse(AccessibilityCapturePolicy.isSendButton(role: "AXTextField", labels: ["Send"]))
        XCTAssertFalse(AccessibilityCapturePolicy.isSendButton(role: "AXButton", labels: ["Attach file"]))
    }

    func testComposerCanShowTheEndOfALongDictationAndRejectHiddenText() {
        let visible = CFRange(location: 60, length: 12)
        XCTAssertTrue(AccessibilityCapturePolicy.includesInsertedCharacter(endingAt: 72, visibleRange: visible))
        XCTAssertFalse(AccessibilityCapturePolicy.includesInsertedCharacter(endingAt: 60, visibleRange: visible))
        XCTAssertFalse(AccessibilityCapturePolicy.includesInsertedCharacter(endingAt: 80, visibleRange: visible))
        XCTAssertFalse(AccessibilityCapturePolicy.includesInsertedCharacter(endingAt: 12, visibleRange: CFRange()))
    }

    func testDictationStatusReportsDoneOnlyAfterInsertionConfirmation() {
        XCTAssertEqual(PasteDeliveryStatus.confirming.message, "⏳ Confirming insertion...")
        XCTAssertEqual(PasteDeliveryStatus.confirmed.message, "✅ Done")
        XCTAssertEqual(PasteDeliveryStatus.copyAvailable.message, "📋 Paste not confirmed — result ready to copy")
    }

    func testChatGPTPasteRequiresTheSameVerifiedFieldFromRecordingThroughDelivery() {
        XCTAssertTrue(PasteService.requiresVerifiedTarget(for: "com.openai.codex"))
        XCTAssertFalse(PasteService.requiresVerifiedTarget(for: "com.apple.Notes"))
        XCTAssertFalse(PasteService.shouldPostPaste(
            requiresVerifiedTarget: true,
            hasRecordingTarget: false,
            hasPasteTarget: true,
            targetsMatch: true
        ))
        XCTAssertFalse(PasteService.shouldPostPaste(
            requiresVerifiedTarget: true,
            hasRecordingTarget: true,
            hasPasteTarget: false,
            targetsMatch: true
        ))
        XCTAssertFalse(PasteService.shouldPostPaste(
            requiresVerifiedTarget: true,
            hasRecordingTarget: true,
            hasPasteTarget: true,
            targetsMatch: false
        ))
        XCTAssertTrue(PasteService.shouldPostPaste(
            requiresVerifiedTarget: true,
            hasRecordingTarget: true,
            hasPasteTarget: true,
            targetsMatch: true
        ))
        XCTAssertTrue(PasteService.shouldPostPaste(
            requiresVerifiedTarget: false,
            hasRecordingTarget: false,
            hasPasteTarget: false,
            targetsMatch: true
        ))
    }

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

    func testEmptyComposerAnchorsTheCorrectedChineseName() {
        let insertedText = "请核对刘俊炎提交的名单。"
        let correctedText = "请核对刘俊言提交的名单。"
        let before = TextFieldSnapshot(
            text: "",
            selectedRange: NSRange(location: 0, length: 0),
            hasMarkedText: false
        )
        let after = TextFieldSnapshot(
            text: insertedText,
            selectedRange: NSRange(location: (insertedText as NSString).length, length: 0),
            hasMarkedText: false
        )

        let region = AnchoredTextRegion.confirmed(
            before: before,
            after: after,
            insertedText: insertedText,
            sameTarget: true
        )

        XCTAssertEqual(region?.candidate(in: correctedText), correctedText)
        XCTAssertEqual(
            region?.candidate(in: correctedText, selectedRange: NSRange(location: 3, length: 3)),
            correctedText
        )
        XCTAssertTrue(EditTracker.shouldAnalyzeEditForTesting(original: insertedText, edited: correctedText))
        XCTAssertEqual(
            EditTracker.computeDiffForTesting(original: insertedText, edited: correctedText).first?.removed,
            "炎"
        )
        XCTAssertEqual(
            EditTracker.computeDiffForTesting(original: insertedText, edited: correctedText).first?.inserted,
            "言"
        )
        XCTAssertNil(AnchoredTextRegion.confirmed(
            before: before,
            after: after,
            insertedText: insertedText,
            sameTarget: false
        ))
    }

    func testConfirmsVisibleChatGPTInsertionWhileUserSelectsAName() {
        let insertedText = "请核对刘俊炎提交的名单。"
        let before = TextFieldSnapshot(
            text: "",
            selectedRange: NSRange(location: 0, length: 0),
            markedTextStatus: .absent
        )
        let after = TextFieldSnapshot(
            text: insertedText,
            selectedRange: NSRange(location: 3, length: 3),
            markedTextStatus: .absent
        )

        let region = AnchoredTextRegion.confirmed(
            before: before,
            after: after,
            insertedText: insertedText,
            sameTarget: true,
            allowSelectionWithinInsertedText: true
        )

        XCTAssertEqual(region?.candidate(in: "请核对刘俊言提交的名单。"), "请核对刘俊言提交的名单。")
        XCTAssertEqual(
            region?.candidate(
                in: "请核对刘俊言提交的名单。",
                selectedRange: NSRange(location: 3, length: 3)
            ),
            "请核对刘俊言提交的名单。"
        )
        XCTAssertNil(AnchoredTextRegion.confirmed(
            before: before,
            after: after,
            insertedText: insertedText,
            sameTarget: false,
            allowSelectionWithinInsertedText: true
        ))
        XCTAssertNil(AnchoredTextRegion.confirmed(
            before: before,
            after: TextFieldSnapshot(
                text: insertedText,
                selectedRange: NSRange(location: (insertedText as NSString).length, length: 0),
                markedTextStatus: .absent
            ),
            insertedText: insertedText + " wrong",
            sameTarget: true,
            allowSelectionWithinInsertedText: true
        ))
        XCTAssertNil(AnchoredTextRegion.confirmed(
            before: before,
            after: TextFieldSnapshot(
                text: insertedText,
                selectedRange: NSRange(location: (insertedText as NSString).length + 1, length: 0),
                markedTextStatus: .absent
            ),
            insertedText: insertedText,
            sameTarget: true,
            allowSelectionWithinInsertedText: true
        ))
        XCTAssertNotNil(AnchoredTextRegion.confirmed(
            before: before,
            after: TextFieldSnapshot(
                text: insertedText,
                selectedRange: NSRange(location: (insertedText as NSString).length, length: 0),
                markedTextStatus: .absent
            ),
            insertedText: insertedText,
            sameTarget: true
        ))
    }

    func testVerifiedStructuralEmptyProseMirrorParagraphCanBeReplacedByExactDictation() {
        let insertedText = "请把名单发给刘俊年。"
        let before = TextFieldSnapshot(
            text: "\n",
            selectedRange: NSRange(location: 0, length: 0),
            markedTextStatus: .unavailable
        )
        let after = TextFieldSnapshot(
            text: insertedText,
            selectedRange: NSRange(location: 6, length: 0),
            markedTextStatus: .unavailable
        )

        let region = AnchoredTextRegion.confirmed(
            before: before, after: after, insertedText: insertedText, sameTarget: true,
            allowSelectionWithinInsertedText: true, isStructuralEmptyParagraph: true
        )
        let retainedBreak = TextFieldSnapshot(
            text: insertedText + "\n", selectedRange: after.selectedRange, markedTextStatus: .unavailable
        )
        XCTAssertEqual(AnchoredTextRegion.confirmed(
            before: before, after: retainedBreak, insertedText: insertedText, sameTarget: true,
            allowSelectionWithinInsertedText: true, isStructuralEmptyParagraph: true
        )?.suffix, "\n")
        XCTAssertEqual(region?.candidate(in: "请把名单发给刘俊言。"), "请把名单发给刘俊言。")
    }

    func testStructuralEmptyComposerFallbackRejectsDraftsWrongTargetsAndComposition() {
        let insertedText = "Please send the file."
        let before = TextFieldSnapshot(
            text: "\n",
            selectedRange: NSRange(location: 0, length: 0),
            markedTextStatus: .unavailable
        )
        let after = TextFieldSnapshot(
            text: insertedText,
            selectedRange: NSRange(location: (insertedText as NSString).length, length: 0),
            markedTextStatus: .unavailable
        )
        func proves(
            before: TextFieldSnapshot = before,
            after: TextFieldSnapshot = after,
            sameTarget: Bool = true,
            isVerifiedStructuralEmptyParagraph: Bool = true
        ) -> Bool {
            AnchoredTextRegion.confirmed(
                before: before, after: after, insertedText: insertedText, sameTarget: sameTarget,
                allowSelectionWithinInsertedText: true, isStructuralEmptyParagraph: isVerifiedStructuralEmptyParagraph
            ) != nil
        }

        XCTAssertFalse(proves(sameTarget: false))
        XCTAssertFalse(proves(isVerifiedStructuralEmptyParagraph: false))
        XCTAssertFalse(proves(before: TextFieldSnapshot(
            text: "draft",
            selectedRange: NSRange(location: 0, length: 0),
            markedTextStatus: .unavailable
        )))
        XCTAssertFalse(proves(before: TextFieldSnapshot(
            text: " ",
            selectedRange: NSRange(location: 0, length: 0),
            markedTextStatus: .unavailable
        )))
        XCTAssertFalse(proves(before: TextFieldSnapshot(
            text: "\n",
            selectedRange: NSRange(location: 1, length: 0),
            markedTextStatus: .unavailable
        )))
        XCTAssertFalse(proves(after: TextFieldSnapshot(
            text: insertedText + " changed",
            selectedRange: NSRange(location: insertedText.utf16.count, length: 0),
            markedTextStatus: .unavailable
        )))
        let outOfRangeSelection = TextFieldSnapshot(
            text: insertedText,
            selectedRange: NSRange(location: insertedText.utf16.count + 1, length: 0),
            markedTextStatus: .unavailable
        )
        XCTAssertFalse(proves(after: outOfRangeSelection))
        XCTAssertFalse(proves(before: TextFieldSnapshot(
            text: "\n",
            selectedRange: NSRange(location: 0, length: 0),
            markedTextStatus: .present
        )))
    }

    func testStructuralEmptyParagraphRequiresTheExactAccessibilityTreeShape() {
        func matches(
            value: String = "\n",
            selectedRange: NSRange = NSRange(location: 0, length: 0),
            markedTextStatus: MarkedTextStatus = .unavailable,
            editorRole: String = "AXTextArea",
            editorClasses: [String] = ["ProseMirror", "ProseMirror-focused"],
            childCount: Int = 1,
            childRole: String? = "AXGroup",
            childValue: String? = "",
            childTitle: String? = "",
            grandchildCount: Int? = 0
        ) -> Bool {
            AccessibilityCapturePolicy.isStructuralEmptyProseMirrorParagraph(
                value: value,
                selection: selectedRange,
                markedTextStatus: markedTextStatus,
                editorRole: editorRole,
                editorClasses: editorClasses,
                childCount: childCount,
                childRole: childRole,
                childValue: childValue,
                childTitle: childTitle,
                grandchildCount: grandchildCount
            )
        }

        XCTAssertTrue(matches())
        XCTAssertFalse(matches(value: " "))
        XCTAssertFalse(matches(value: "\nuser text"))
        XCTAssertFalse(matches(selectedRange: NSRange(location: 1, length: 0)))
        XCTAssertFalse(matches(markedTextStatus: .present))
        XCTAssertFalse(matches(editorRole: "AXTextField"))
        XCTAssertFalse(matches(editorClasses: ["RichText"]))
        XCTAssertFalse(matches(childCount: 2))
        XCTAssertFalse(matches(childRole: "AXStaticText"))
        XCTAssertFalse(matches(childValue: "user text"))
        XCTAssertFalse(matches(childTitle: "document text"))
        XCTAssertFalse(matches(grandchildCount: 1))
        XCTAssertFalse(matches(grandchildCount: nil))
    }

    func testInsertionAtStartOfRealDraftPreservesItsOriginalText() {
        let insertedText = "dictation"
        let existingDraft = "existing draft"
        let before = TextFieldSnapshot(
            text: existingDraft,
            selectedRange: NSRange(location: 0, length: 0),
            markedTextStatus: .absent
        )
        let after = TextFieldSnapshot(
            text: insertedText + existingDraft,
            selectedRange: NSRange(location: (insertedText as NSString).length, length: 0),
            markedTextStatus: .absent
        )

        let region = AnchoredTextRegion.confirmed(
            before: before,
            after: after,
            insertedText: insertedText,
            sameTarget: true,
            allowSelectionWithinInsertedText: true
        )

        XCTAssertEqual(region?.prefix, "")
        XCTAssertEqual(region?.suffix, existingDraft)
        XCTAssertEqual(region?.candidate(in: "corrected" + existingDraft), "corrected")
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
        XCTAssertFalse(PasteService.isSavedApplicationFrontmost(frontmostPID: nil, targetPID: 10))
        XCTAssertFalse(PasteService.isSavedApplicationFrontmost(frontmostPID: 9, targetPID: 10))
        XCTAssertTrue(PasteService.isSavedApplicationFrontmost(frontmostPID: 10, targetPID: 10))
        XCTAssertTrue(PasteService.shouldRestorePasteboard(currentChangeCount: 4, writtenChangeCount: 4))
        XCTAssertFalse(PasteService.shouldRestorePasteboard(currentChangeCount: 5, writtenChangeCount: 4))
        XCTAssertFalse(PasteService.shouldRestorePasteboardAfterConfirmation(
            confirmed: false,
            currentChangeCount: 4,
            writtenChangeCount: 4
        ))
        XCTAssertTrue(PasteService.shouldRestorePasteboardAfterConfirmation(
            confirmed: true,
            currentChangeCount: 4,
            writtenChangeCount: 4
        ))
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
