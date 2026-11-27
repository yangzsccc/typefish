import AppKit
import XCTest
@testable import TypeFish

final class HotkeyManagerTests: XCTestCase {
    func testActiveToggleTapConsumesOnlyOptionSpaceDownAndItsMatchingUp() {
        XCTAssertEqual(
            HotkeyManager.toggleTapDecisionForTesting(
                eventType: .keyDown, keyCode: 49, modifiers: [.option],
                isConsumingSequence: false
            ),
            .consumeAndToggle
        )
        XCTAssertEqual(
            HotkeyManager.toggleTapDecisionForTesting(
                eventType: .keyDown, keyCode: 49, modifiers: [],
                isConsumingSequence: true
            ),
            .consume
        )
        XCTAssertEqual(
            HotkeyManager.toggleTapDecisionForTesting(
                eventType: .keyUp, keyCode: 49, modifiers: [],
                isConsumingSequence: true
            ),
            .consume
        )
    }

    func testActiveToggleTapPassesThroughOtherKeysAndModifierCombinations() {
        let unrelated: [(CGEventType, UInt16, NSEvent.ModifierFlags)] = [
            (.keyDown, 49, []),
            (.keyDown, 49, [.shift, .option]),
            (.keyDown, 49, [.control, .option]),
            (.keyDown, 49, [.function, .option]),
            (.keyDown, 18, [.option]),
            (.keyUp, 49, [.option])
        ]
        for (eventType, keyCode, modifiers) in unrelated {
            XCTAssertEqual(
                HotkeyManager.toggleTapDecisionForTesting(
                    eventType: eventType, keyCode: keyCode, modifiers: modifiers,
                    isConsumingSequence: false
                ),
                .passThrough
            )
        }
    }

    func testAutorepeatAfterTapRecoveryDoesNotToggleAndReleaseClearsLatch() {
        let repeatedDown = HotkeyManager.toggleTapDecisionForTesting(
            eventType: .keyDown, keyCode: 49, modifiers: [.option],
            isConsumingSequence: false, hasOrphanedKeyUp: true, isAutorepeat: true
        )
        XCTAssertEqual(repeatedDown, .consumeAndLatch)

        let release = HotkeyManager.toggleTapDecisionForTesting(
            eventType: .keyUp, keyCode: 49, modifiers: [],
            isConsumingSequence: true, hasOrphanedKeyUp: true
        )
        XCTAssertEqual(release, .consume)

        let nextFreshPress = HotkeyManager.toggleTapDecisionForTesting(
            eventType: .keyDown, keyCode: 49, modifiers: [.option],
            isConsumingSequence: false, hasOrphanedKeyUp: false, isAutorepeat: false
        )
        XCTAssertEqual(nextFreshPress, .consumeAndToggle)
    }

    func testOnlyInitialFreshKeyDownRequestsToggle() {
        let initialDown = HotkeyManager.toggleTapDecisionForTesting(
            eventType: .keyDown, keyCode: 49, modifiers: [.option],
            isConsumingSequence: false
        )
        let repeatDown = HotkeyManager.toggleTapDecisionForTesting(
            eventType: .keyDown, keyCode: 49, modifiers: [.option],
            isConsumingSequence: true, isAutorepeat: true
        )
        XCTAssertEqual(initialDown, .consumeAndToggle)
        XCTAssertEqual(repeatDown, .consume)
    }

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
