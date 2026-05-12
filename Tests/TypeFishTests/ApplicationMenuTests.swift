import XCTest
@testable import TypeFish

final class ApplicationMenuTests: XCTestCase {
    func testMainMenuProvidesNativeQuitAndCloseShortcuts() {
        let menu = ApplicationMenuFactory.makeMainMenu()

        let appMenu = menu.item(at: 0)?.submenu
        let quitItem = appMenu?.items.first { $0.title == "Quit TypeFish" }
        XCTAssertEqual(quitItem?.keyEquivalent, "q")
        XCTAssertEqual(quitItem?.action, #selector(NSApplication.terminate(_:)))

        let fileMenu = menu.item(withTitle: "File")?.submenu
        let closeItem = fileMenu?.items.first { $0.title == "Close Window" }
        XCTAssertEqual(closeItem?.keyEquivalent, "w")
        XCTAssertEqual(closeItem?.action, #selector(NSWindow.performClose(_:)))
    }
}
