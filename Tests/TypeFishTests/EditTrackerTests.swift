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

    func testCorrectionParsingDeduplicatesAndRejectsUnrelatedPairs() {
        let response = """
        Chat GBT → ChatGPT
        Chat GBT → ChatGPT
        Let's → Also
        """

        let corrections = EditTracker.parseCorrectionsForTesting(
            response,
            sourceText: "Please use Chat GBT for this response.",
            editedText: "Please use ChatGPT for this response."
        )

        XCTAssertEqual(corrections.count, 1)
        XCTAssertEqual(corrections.first?.0, "Chat GBT")
        XCTAssertEqual(corrections.first?.1, "ChatGPT")
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

    func testBeforeSendSnapshotOnlyForKnownAXFailingSendApps() {
        XCTAssertFalse(EditTracker.shouldUseBeforeSendSnapshotForTesting(
            bundleIdentifier: "com.openai.codex",
            failedReadCount: 1,
            isTracking: true,
            isAnalyzing: false
        ))

        XCTAssertTrue(EditTracker.shouldUseBeforeSendSnapshotForTesting(
            bundleIdentifier: "com.hnc.Discord",
            failedReadCount: 1,
            isTracking: true,
            isAnalyzing: false
        ))

        XCTAssertFalse(EditTracker.shouldUseBeforeSendSnapshotForTesting(
            bundleIdentifier: "com.apple.TextEdit",
            failedReadCount: 1,
            isTracking: true,
            isAnalyzing: false
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
