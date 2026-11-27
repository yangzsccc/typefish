import XCTest
@testable import TypeFish

final class EditTrackerTests: XCTestCase {
    func testTokenDiffKeepsChangedWordsReadable() {
        let diffs = EditTracker.computeDiffForTesting(
            original: "怎样绕过 Anthropic OpenC 的限制？",
            edited: "怎样绕过 Anthropic OpenAI 的限制？"
        )

        XCTAssertEqual(diffs.count, 1)
        XCTAssertEqual(diffs.first?.removed, "OpenC")
        XCTAssertEqual(diffs.first?.inserted, "OpenAI")
    }

    func testClipboardOverlapRejectsUnrelatedSimilarLengthText() {
        let original = "Let's do better cost control here. It reduces the O3 usage and gives me a better plan."
        let edited = "Also, I have set up the codecs OAuth for you, making sure that you're using OAuth instead of API."

        XCTAssertFalse(EditTracker.hasSignificantOverlapForTesting(original, edited))
    }

    func testClipboardOverlapAllowsTargetedCorrection() {
        let original = "Please use Chat GBT for this response."
        let edited = "Please use ChatGPT for this response."

        XCTAssertTrue(EditTracker.hasSignificantOverlapForTesting(original, edited))
    }

    func testClassifierMustReturnTheTermAtTheActualEdit() {
        let original = "Keep Claude-Code and use Cloud Code"
        let edited = "Keep Claude-Code and use Claude Code"
        XCTAssertEqual(EditTracker.shared.validatedTerm("Claude Code", original: original, edited: edited), "Claude Code")
        XCTAssertNil(EditTracker.shared.validatedTerm("Claude-Code", original: original, edited: edited))
        XCTAssertNil(EditTracker.shared.validatedTerm("Keep", original: original, edited: edited))
        XCTAssertNil(EditTracker.shared.validatedTerm("NONE", original: original, edited: edited))
        XCTAssertEqual(EditTracker.shared.validatedTerm("Claude Code", original: "Cloud Code", edited: "Claude Code"), "Claude Code")
        XCTAssertEqual(EditTracker.shared.validatedTerm("陈晨", original: "请交给陈辰", edited: "请交给陈晨"), "陈晨")
        XCTAssertEqual(
            EditTracker.shared.validatedTerm(
                "刘俊彦",
                original: "请将名单交给刘俊言核对",
                edited: "请将名单交给刘俊彦核对"
            ),
            "刘俊彦"
        )
        XCTAssertEqual(
            EditTracker.shared.validatedTerm(
                "刘俊彦",
                original: "请将名单交给刘俊延核对",
                edited: "请将名单交给刘俊彦核对"
            ),
            "刘俊彦"
        )
        XCTAssertEqual(
            EditTracker.shared.validatedTerm(
                "俊彦",
                original: "请联系刘俊言处理",
                edited: "请联系刘俊彦处理"
            ),
            "俊彦"
        )
    }

    func testSingleWordPositiveKeepsUnchangedTitleCaseNameNeighbor() {
        let tracker = EditTracker.shared
        XCTAssertEqual(
            tracker.validatedTerm(
                "Claude",
                original: "Please try Cloud Code for the project.",
                edited: "Please try Claude Code for the project."
            ),
            "Claude Code"
        )
        XCTAssertEqual(
            tracker.validatedTerm("Claude", original: "Cloude Code", edited: "Claude Code"),
            "Claude Code"
        )
    }

    func testSingleWordPositiveDoesNotExpandAcrossUnrelatedOrPunctuatedNeighbors() {
        let tracker = EditTracker.shared
        XCTAssertEqual(
            tracker.validatedTerm("Xochitl", original: "Use Sochiel tomorrow.", edited: "Use Xochitl tomorrow."),
            "Xochitl"
        )
        XCTAssertEqual(
            tracker.validatedTerm("Claude", original: "Try Cloud, Code now.", edited: "Try Claude, Code now."),
            "Claude"
        )
        XCTAssertEqual(
            tracker.validatedTerm("Claude", original: "Try Cloud", edited: "Try Claude"),
            "Claude"
        )
        XCTAssertNil(tracker.validatedTerm("NONE", original: "Cloude Code", edited: "Claude Code"))
    }

    func testEditAnalysisGateAllowsSmallPhoneticCorrection() {
        XCTAssertTrue(EditTracker.shouldAnalyzeEditForTesting(
            original: "Please use Chat GBT for this response.",
            edited: "Please use ChatGPT for this response."
        ))
    }

    func testEditAnalysisGateAllowsCloudToClaudeCorrection() {
        XCTAssertTrue(EditTracker.shouldAnalyzeEditForTesting(
            original: "所以我觉得最好的coding工具是Cloud Code，不是OpenCloud。",
            edited: "所以我觉得最好的coding工具是Claude Code，不是OpenCloud。"
        ))
    }

    func testEditAnalysisGateRejectsLargeLengthDifference() {
        XCTAssertFalse(EditTracker.shouldAnalyzeEditForTesting(
            original: "Use API for this request.",
            edited: "Use Application for this request."
        ))
    }

    func testEditAnalysisGateRejectsNonPhoneticReplacement() {
        XCTAssertFalse(EditTracker.shouldAnalyzeEditForTesting(
            original: "Send this to OpenClaw.",
            edited: "Send this to Calendar."
        ))
    }

    func testClipboardSnapshotKeepsCopiedTextAfterSentinelReplacement() {
        XCTAssertEqual(
            ContextReader.usableClipboardSnapshotTextForTesting(
                copied: "所以我觉得最好的coding工具是Claude Code，不是OpenCloud。",
                oldString: "所以我觉得最好的coding工具是Claude Code，不是OpenCloud。",
                changed: true
            ),
            "所以我觉得最好的coding工具是Claude Code，不是OpenCloud。"
        )
    }

    func testClipboardSnapshotRejectsUnchangedStaleClipboardText() {
        XCTAssertNil(ContextReader.usableClipboardSnapshotTextForTesting(
            copied: "那现在最好的coding工具是Cloud Code还是OpenCloud？",
            oldString: "那现在最好的coding工具是Cloud Code还是OpenCloud？",
            changed: false
        ))
    }
}
