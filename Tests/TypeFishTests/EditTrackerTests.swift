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
}
