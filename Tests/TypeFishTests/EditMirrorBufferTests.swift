import AppKit
import XCTest
@testable import TypeFish

final class EditMirrorBufferTests: XCTestCase {
    func testCaptureModeRoutesKnownInputSurfaces() {
        XCTAssertEqual(EditTracker.captureModeForTesting(bundleIdentifier: "com.openai.codex"), .eventMirror)
        XCTAssertEqual(EditTracker.captureModeForTesting(bundleIdentifier: "com.google.Chrome"), .clipboardSnapshot)
        XCTAssertEqual(EditTracker.captureModeForTesting(bundleIdentifier: "com.apple.Safari"), .clipboardSnapshot)
        XCTAssertEqual(EditTracker.captureModeForTesting(bundleIdentifier: "com.hnc.Discord"), .clipboardSnapshot)
        XCTAssertEqual(EditTracker.captureModeForTesting(bundleIdentifier: "com.tinyspeck.slackmacgap"), .clipboardSnapshot)
        XCTAssertEqual(EditTracker.captureModeForTesting(bundleIdentifier: "com.apple.Terminal"), .terminalShellIntegration)
        XCTAssertEqual(EditTracker.captureModeForTesting(bundleIdentifier: "com.mitchellh.ghostty"), .terminalShellIntegration)
        XCTAssertEqual(EditTracker.captureModeForTesting(bundleIdentifier: "com.apple.TextEdit"), .accessibility)
        XCTAssertEqual(EditTracker.captureModeForTesting(bundleIdentifier: nil), .accessibility)
    }

    func testEventMirrorReconstructsCodexStyleSelectAllReplacement() {
        var mirror = EditMirrorBuffer(originalText: "所以我觉得最好的coding工具是Cloud Code，不是OpenCloud。")

        mirror.apply(.commandKey(keyCode: 0, characters: "a"))
        mirror.apply(.text("所以我觉得最好的coding工具是Claude Code，不是OpenCloud。"))

        XCTAssertTrue(mirror.isReliable)
        XCTAssertEqual(
            mirror.currentText,
            "所以我觉得最好的coding工具是Claude Code，不是OpenCloud。"
        )
        XCTAssertTrue(EditTracker.shouldAnalyzeEditForTesting(
            original: "所以我觉得最好的coding工具是Cloud Code，不是OpenCloud。",
            edited: mirror.currentText
        ))
    }

    func testEventMirrorHandlesKeyboardCorrectionInsideText() {
        let original = "Please use Chat GBT here."
        var mirror = EditMirrorBuffer(originalText: original)

        for _ in 0..<9 {
            mirror.apply(.leftArrow)
        }
        mirror.apply(.deleteForward)
        mirror.apply(.deleteForward)
        mirror.apply(.deleteForward)
        mirror.apply(.text("GPT"))

        XCTAssertTrue(mirror.isReliable)
        XCTAssertEqual(mirror.currentText, "Please use Chat GPT here.")
        XCTAssertTrue(EditTracker.shouldAnalyzeEditForTesting(
            original: original,
            edited: mirror.currentText
        ))
    }

    func testEventMirrorStopsBeingAuthoritativeAfterUnsupportedCommand() {
        var mirror = EditMirrorBuffer(originalText: "Use Cloud Code here.")

        mirror.apply(.commandKey(keyCode: 6, characters: "z"))
        mirror.apply(.text("Claude"))

        XCTAssertFalse(mirror.isReliable)
        XCTAssertNil(mirror.authoritativeTextForAnalysis)
    }
}
