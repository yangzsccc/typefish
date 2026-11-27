import XCTest
@testable import TypeFish

final class VersionTests: XCTestCase {
    func testCurrentVersionIsV261() {
        XCTAssertEqual(Updater.currentVersion, "2.6.1")
    }
}
