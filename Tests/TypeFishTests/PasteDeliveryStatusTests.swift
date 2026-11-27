import XCTest
@testable import TypeFish

final class PasteDeliveryStatusTests: XCTestCase {
    func testStandardEditorRolesAreRecognizedAsPasteTargets() {
        for role in ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXWebArea"] {
            let assessment = PasteTargetAccessibility.assessment(
                role: role,
                valueIsSettable: false,
                selectedTextIsSettable: false
            )
            if role == "AXWebArea" {
                XCTAssertEqual(assessment, .unknown, role)
            } else {
                XCTAssertEqual(assessment, .editable, role)
            }
        }
    }

    func testExplicitControlsAreRecognizedAsNonEditorTargets() {
        for role in ["AXToolbar", "AXButton", "AXTabGroup", "AXStaticText"] {
            let assessment = PasteTargetAccessibility.assessment(
                role: role,
                valueIsSettable: false,
                selectedTextIsSettable: false
            )
            XCTAssertEqual(assessment, .nonEditable, role)
        }
    }

    func testAmbiguousCustomEditorsUseWritableAccessibilityAttributes() {
        for role in ["AXGroup", "AXCell", "AXScrollArea", "AXWebArea", "AXOutline"] {
            XCTAssertEqual(
                PasteTargetAccessibility.assessment(role: role, valueIsSettable: true, selectedTextIsSettable: false),
                .editable,
                role
            )
            XCTAssertEqual(
                PasteTargetAccessibility.assessment(role: role, valueIsSettable: false, selectedTextIsSettable: true),
                .editable,
                role
            )
            XCTAssertEqual(
                PasteTargetAccessibility.assessment(role: role, valueIsSettable: false, selectedTextIsSettable: false),
                .unknown,
                role
            )
        }
        XCTAssertEqual(PasteTargetAccessibility.assessment(role: nil, valueIsSettable: false, selectedTextIsSettable: false), .unknown)
        XCTAssertEqual(PasteTargetAccessibility.assessment(role: "AXCustomEditor", valueIsSettable: false, selectedTextIsSettable: false), .unknown)
    }

    func testSentButUnverifiedPasteHasAccurateStatus() {
        XCTAssertEqual(PasteDeliveryStatus.unconfirmed.message, "⚠️ Insertion could not be verified")
        XCTAssertEqual(PasteDeliveryStatus.copyAvailable.message, "📋 Paste not confirmed — result ready to copy")
    }

    func testFallbackResultWindowUsesFiniteDismissalTimeout() {
        XCTAssertEqual(OverlayPanel.resultAutoDismissInterval, 8)
    }
}
