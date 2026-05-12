import XCTest
@testable import TypeFish

final class VersionTests: XCTestCase {
    func testCurrentVersionIsV25() {
        XCTAssertEqual(Updater.currentVersion, "2.5.0")
    }
}
