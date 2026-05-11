import AppKit
import XCTest
@testable import TypeFish

final class OverlayPanelE2ETests: XCTestCase {
    func testAutoLearnOverlayCreatesVisibleWindow() throws {
        guard ProcessInfo.processInfo.environment["TYPEFISH_RUN_E2E"] == "1" else {
            throw XCTSkip("Set TYPEFISH_RUN_E2E=1 to run the overlay E2E test.")
        }

        let overlay = OverlayPanel()
        try runOnMainThread {
            overlay.showAutoLearn(wrong: "cloud", right: "Claude", onUndo: {})
        }

        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let state = try runOnMainThread {
            overlay.autoLearnWindowStateForTesting()
        }

        XCTAssertTrue(state.isVisible)
        XCTAssertGreaterThan(state.alpha, 0.5)
        XCTAssertNotNil(state.frame)

        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let matchingWindows = windows.filter { window in
            (window[kCGWindowOwnerPID as String] as? pid_t) == getpid()
                && (window[kCGWindowName as String] as? String) == OverlayPanel.autoLearnWindowTitle
        }
        XCTAssertFalse(matchingWindows.isEmpty)

        try? Self.captureScreen(path: "/tmp/typefish-autolearn-overlay-e2e.png")
    }

    private static func captureScreen(path: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}

private func runOnMainThread<T>(_ work: @escaping () throws -> T) throws -> T {
    if Thread.isMainThread {
        return try work()
    }

    var result: Result<T, Error>!
    DispatchQueue.main.sync {
        result = Result {
            try work()
        }
    }
    return try result.get()
}
