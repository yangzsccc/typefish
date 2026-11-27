import XCTest
@testable import TypeFish

final class NativePasteCommandTests: XCTestCase {
    func testUsesOnlyTheStandardUnmodifiedPasteMenuItem() {
        XCTAssertTrue(NativePasteCommand.usesPasteShortcut(character: "v", modifiers: 0))
        XCTAssertFalse(NativePasteCommand.usesPasteShortcut(character: "V", modifiers: 1))
        XCTAssertFalse(NativePasteCommand.usesPasteShortcut(character: "V", modifiers: 8))
        XCTAssertFalse(NativePasteCommand.usesPasteShortcut(character: nil, modifiers: 0))
        XCTAssertFalse(NativePasteCommand.usesPasteShortcut(character: "V", modifiers: nil))
        XCTAssertFalse(NativePasteCommand.usesPasteShortcut(character: "C", modifiers: 0))
    }
}
