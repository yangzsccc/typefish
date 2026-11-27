import AppKit
import XCTest
@testable import TypeFish

final class OverlayPanelE2ETests: XCTestCase {
    func testFeedbackPanelCannotBecomeKeyOrMain() {
        let panel = NonactivatingOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.isFloatingPanel)
    }

    func testCopyResultKeepsAUsableCopyEntry() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TypeFishOverlayCopyTest"))
        defer { pasteboard.releaseGlobally() }

        OverlayPanel.copyResult("刘俊彦是一只大大的小猪", to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "刘俊彦是一只大大的小猪")
    }

    func testAutoLearnOverlayCreatesVisibleWindow() throws {
        guard ProcessInfo.processInfo.environment["TYPEFISH_RUN_E2E"] == "1" else {
            throw XCTSkip("Set TYPEFISH_RUN_E2E=1 to run the overlay E2E test.")
        }

        let overlay = OverlayPanel()
        try runOnMainThread {
            overlay.showLearnedSpelling("Claude Code", onUndo: {})
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

        if let windowID = matchingWindows.first?[kCGWindowNumber as String] as? Int {
            try Self.captureWindow(id: windowID, path: "/tmp/typefish-autolearn-overlay-e2e.png")
        }
    }

    func testCopyFallbackResultWindowAutomaticallyDismisses() throws {
        guard ProcessInfo.processInfo.environment["TYPEFISH_RUN_E2E"] == "1" else {
            throw XCTSkip("Set TYPEFISH_RUN_E2E=1 to run the result-window E2E test.")
        }

        let overlay = OverlayPanel()
        try runOnMainThread {
            overlay.showResult("TypeFish clipboard fallback test")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(try runOnMainThread { overlay.resultWindowIsVisibleForTesting() })

        RunLoop.current.run(until: Date().addingTimeInterval(OverlayPanel.resultAutoDismissInterval - 1))
        try runOnMainThread {
            overlay.showResult("TypeFish replacement fallback test")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1.3))
        XCTAssertTrue(try runOnMainThread { overlay.resultWindowIsVisibleForTesting() })
        try runOnMainThread { overlay.dismiss() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(try runOnMainThread { overlay.resultWindowIsVisibleForTesting() })

        // AppKit can coalesce timers while XCTest pumps the run loop.
        let deadline = Date().addingTimeInterval(OverlayPanel.resultAutoDismissInterval + 1)
        while Date() < deadline, try runOnMainThread({ overlay.resultWindowIsVisibleForTesting() }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertFalse(try runOnMainThread { overlay.resultWindowIsVisibleForTesting() })
    }

    private static func captureWindow(id: Int, path: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-l", String(id), path]
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
