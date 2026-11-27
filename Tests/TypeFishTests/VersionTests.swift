import XCTest
@testable import TypeFish

final class VersionTests: XCTestCase {
    func testCurrentVersionIsV26() {
        XCTAssertEqual(Updater.currentVersion, "2.6.0")
    }
}
