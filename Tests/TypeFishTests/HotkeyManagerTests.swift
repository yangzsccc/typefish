import AppKit
import XCTest
@testable import TypeFish

final class HotkeyManagerTests: XCTestCase {
    func testLightroomRatingDigitsPassThroughWhenEditTrackingIsIdle() {
        for keyCode in [18, 19, 20, 21, 23] {
            let decision = HotkeyManager.eventTapDecisionForTesting(
                keyCode: UInt16(keyCode),
                modifiers: [],
                isTrackingEdits: false,
                isReplayingTrackedEnter: false,
                shouldInterceptEnter: false
            )

            XCTAssertEqual(decision, .passThrough)
        }
    }

    func testOnlyTrackedEnterCanBeSwallowedByEventTap() {
        XCTAssertEqual(
            HotkeyManager.eventTapDecisionForTesting(
                keyCode: 36,
                modifiers: [],
                isTrackingEdits: true,
                isReplayingTrackedEnter: false,
                shouldInterceptEnter: true
            ),
            .interceptTrackedEnter
        )

        XCTAssertEqual(
            HotkeyManager.eventTapDecisionForTesting(
                keyCode: 18,
                modifiers: [],
                isTrackingEdits: true,
                isReplayingTrackedEnter: false,
                shouldInterceptEnter: true
            ),
            .trackAndPassThrough(.text("1"), triggerEnter: false)
        )
    }

    func testSpaceHotkeysAreHandledByRegisteredHotkeysNotEventTap() {
        XCTAssertEqual(
            HotkeyManager.eventTapDecisionForTesting(
                keyCode: 49,
                modifiers: [.option],
                isTrackingEdits: false,
                isReplayingTrackedEnter: false,
                shouldInterceptEnter: false
            ),
            .passThrough
        )
    }

    func testRegisteredSpaceHotkeysAreIgnoredEvenDuringEditTracking() {
        let registeredModifiers: [NSEvent.ModifierFlags] = [
            [.option],
            [.control, .option],
            [.control, .option, .command]
        ]

        for modifiers in registeredModifiers {
            XCTAssertEqual(
                HotkeyManager.eventTapDecisionForTesting(
                    keyCode: 49,
                    modifiers: modifiers,
                    isTrackingEdits: true,
                    isReplayingTrackedEnter: false,
                    shouldInterceptEnter: false
                ),
                .passThrough
            )
        }
    }
}
