import AppKit
import ApplicationServices
import XCTest
@testable import TypeFish

/// Opt-in tests: these launch controlled synthetic fields and send real paste events.
/// Run only in a desktop session where the test process has Accessibility permission.
@MainActor
final class ContextSnapshotE2ETests: XCTestCase {
    private struct FixtureText {
        let marker: String
        let prefix: String
        let suffix: String
        let original: String
        let corrected: String

        var initial: String { marker + prefix + suffix }
        var expectedAfterPaste: String { marker + prefix + original + suffix }
        var expectedAfterEdit: String { marker + prefix + corrected + suffix }
        var insertionOffset: Int { ((marker + prefix) as NSString).length }
    }

    func testAnchoredPasteAndOwnedEditInTextEdit() async throws {
        try requireOptIn()
        let fixture = makeFixture()
        let clipboard = ClipboardSnapshot.capture()
        let wasRunning = Self.isTextEditRunning()
        try Self.openTextEditDocument(with: fixture.initial)
        defer {
            clipboard.restore()
            try? Self.closeTextEditDocument(containing: fixture.marker)
            if !wasRunning { try? Self.quitTextEditIfNoDocuments() }
        }

        try await exerciseAnchoredPaste(fixture, expectedBundleID: "com.apple.TextEdit")
    }

    func testAnchoredPasteAndOwnedEditInChromeContentEditable() async throws {
        try requireOptIn()
        let chromePath = try Self.chromeAppPath()
        let fixture = makeFixture()
        let clipboard = ClipboardSnapshot.capture()
        let profile = Self.chromeProfileURL()
        let htmlURL = try Self.openChromeComposer(appPath: chromePath, profile: profile, fixture: fixture)
        defer {
            clipboard.restore()
            Self.killChromeComposer(profile: profile)
            try? FileManager.default.removeItem(at: htmlURL)
        }

        let pid = try Self.chromeComposerProcessID(profile: profile)
        try Self.activateChromeComposer(pid: pid)
        try await exerciseAnchoredPaste(fixture, expectedPID: pid)
    }

    private func exerciseAnchoredPaste(
        _ fixture: FixtureText,
        expectedBundleID: String? = nil,
        expectedPID: pid_t? = nil
    ) async throws {
        guard AXIsProcessTrusted() else {
            XCTFail("Enable Accessibility for the test runner before running this opt-in test.")
            return
        }
        let candidate: NSRunningApplication?
        if let expectedPID {
            candidate = NSRunningApplication(processIdentifier: expectedPID)
        } else if let expectedBundleID {
            candidate = NSRunningApplication.runningApplications(withBundleIdentifier: expectedBundleID).first
        } else {
            candidate = nil
        }
        guard let app = candidate else {
            XCTFail("The synthetic editor process is unavailable")
            return
        }
        // Opening a new app or closing the previous fixture can briefly change focus.
        // Before sending input, confirm the exact test process and the unique draft.
        for _ in 0..<12 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
               let field = Self.focusedEditableElement(in: app),
               Self.stringAttribute(kAXValueAttribute as CFString, from: field) == fixture.initial {
                break
            }
            app.activate()
            try await Task.sleep(nanoseconds: 180_000_000)
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            XCTFail("The synthetic editor did not become the foreground app")
            return
        }

        guard let focused = Self.focusedEditableElement(in: app),
              let initialText = Self.stringAttribute(kAXValueAttribute as CFString, from: focused) else {
            XCTFail("The controlled app did not expose its focused editable field through Accessibility")
            return
        }
        guard initialText == fixture.initial else {
            XCTFail("Focused field did not exactly match the unique fixture; refusing to paste")
            return
        }
        let initialSelection = NSRange(location: fixture.insertionOffset, length: 0)
        guard await Self.selectAndVerify(initialSelection, on: focused) else {
            XCTFail("Could not verify the insertion point in the synthetic fixture; refusing to paste")
            return
        }

        PasteService.saveFrontmostApp()
        guard PasteService.savedApp?.processIdentifier == app.processIdentifier,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            XCTFail("Foreground destination changed before paste; refusing to send input")
            return
        }
        let (pasted, pending) = PasteService.pasteForLearning(fixture.original)
        guard pasted else {
            XCTFail("PasteService did not paste into the verified synthetic field")
            return
        }
        guard let pending else {
            XCTFail("No pre-paste witness was captured for the verified field")
            return
        }

        // Confirm on a worker, as production does. A short retry accommodates the
        // asynchronous Cmd+V delivery without imposing a fixed delay on the app.
        guard let anchor = await awaitConfirmation(pending) else {
            XCTFail("Insertion was not confirmed in the same field and range")
            return
        }
        guard await Self.read(anchor) == .text(fixture.original) else {
            XCTFail("Anchor did not read the inserted slice; refusing to synthesize an edit")
            return
        }

        guard let stillFocused = Self.focusedEditableElement(in: app) else {
            XCTFail("The verified synthetic field lost accessibility focus")
            return
        }
        guard Self.sameElement(focused, stillFocused),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              Self.stringAttribute(kAXValueAttribute as CFString, from: stillFocused) == fixture.expectedAfterPaste else {
            XCTFail("Field, foreground app, or text changed after confirmation; refusing to synthesize a correction")
            return
        }

        // Select only the inserted span, then use the same real paste mechanism to
        // synthesize a user correction. The unchanged fixture prefix/suffix prove
        // the anchor returns its owned slice rather than the whole field.
        let insertedRange = NSRange(location: fixture.insertionOffset, length: (fixture.original as NSString).length)
        guard await Self.selectAndVerify(insertedRange, on: stillFocused),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            XCTFail("Could not verify the inserted-span selection in the foreground fixture; refusing to send input")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(fixture.corrected, forType: .string) else {
            XCTFail("Could not stage synthetic correction")
            return
        }
        Self.postCommandV()

        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var observation: AnchoredEditObservation = .unavailable
        while ProcessInfo.processInfo.systemUptime < deadline {
            observation = await Self.read(anchor)
            if observation == .text(fixture.corrected) { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(observation, .text(fixture.corrected))
        XCTAssertEqual(Self.stringAttribute(kAXValueAttribute as CFString, from: stillFocused), fixture.expectedAfterEdit)
    }

    private func awaitConfirmation(_ pending: PendingPasteCapture) async -> PostPasteCaptureAnchor? {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let anchor = await Task.detached(priority: .userInitiated, operation: { pending.confirm() }).value { return anchor }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    private static func read(_ anchor: PostPasteCaptureAnchor) async -> AnchoredEditObservation {
        await Task.detached(priority: .utility) { anchor.read(isNonDirectInputMethod: false) }.value
    }

    private static func focusedEditableElement(in app: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(value, to: AXUIElement.self)
        guard let role = stringAttribute(kAXRoleAttribute as CFString, from: element),
              ["AXTextArea", "AXTextField", "AXComboBox", "AXWebArea"].contains(role),
              stringAttribute(kAXValueAttribute as CFString, from: element) != nil,
              selectedRange(from: element) != nil else { return nil }
        return element
    }

    private static func stringAttribute(_ name: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value as? String
    }

    private static func selectedRange(from element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private static func selectAndVerify(_ range: NSRange, on field: AXUIElement) async -> Bool {
        guard setSelectedRange(range, on: field) else { return false }
        for _ in 0..<15 {
            if selectedRange(from: field) == range { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    private static func setSelectedRange(_ range: NSRange, on element: AXUIElement) -> Bool {
        var valueRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &valueRange) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    private static func sameElement(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        CFEqual(lhs, rhs)
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cgSessionEventTap)
    }

    private func requireOptIn() throws {
        guard ProcessInfo.processInfo.environment["TYPEFISH_RUN_E2E"] == "1" else {
            throw XCTSkip("Set TYPEFISH_RUN_E2E=1 to run the controlled-field paste E2E tests.")
        }
    }

    private func makeFixture() -> FixtureText {
        let marker = "TYPEFISH-E2E-\(UUID().uuidString) :: "
        return FixtureText(marker: marker, prefix: "prefix[", suffix: "]suffix", original: "Cloud Code", corrected: "Claude Code")
    }

    private static func openTextEditDocument(with text: String) throws {
        try runAppleScript("""
        tell application "TextEdit"
            activate
            make new document with properties {text:\(appleScriptString(text))}
        end tell
        tell application "System Events" to set frontmost of process "TextEdit" to true
        delay 0.8
        """)
    }

    private static func isTextEditRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").isEmpty
    }

    private static func chromeAppPath() throws -> String {
        let candidates = ["/Applications/Google Chrome.app", "/Applications/Google Chrome.app.app"]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw XCTSkip("Google Chrome is not installed.")
        }
        return path
    }

    private static func chromeProfileURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("typefish-e2e-\(UUID().uuidString)")
    }

    private static func openChromeComposer(appPath: String, profile: URL, fixture: FixtureText) throws -> URL {
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>TypeFish E2E</title>
        <style>body{font:16px sans-serif;margin:40px}#composer{width:760px;min-height:96px;border:1px solid #999;padding:12px;white-space:pre-wrap;outline:none}</style>
        </head><body><div id="composer" role="textbox" contenteditable="true">\(escapeHTML(fixture.initial))</div>
        <script>
        const c=document.getElementById('composer');
        function focusComposer(){c.focus();const r=document.createRange();r.setStart(c.firstChild,\(fixture.insertionOffset));r.collapse(true);const s=getSelection();s.removeAllRanges();s.addRange(r)}
        window.addEventListener('load',()=>setTimeout(focusComposer,300));
        </script></body></html>
        """
        let htmlURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("typefish-e2e-\(UUID().uuidString).html")
        try html.write(to: htmlURL, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-na", appPath, "--args", "--user-data-dir=\(profile.path)", "--no-first-run", "--no-default-browser-check", "--disable-sync", "--disable-default-apps", "--force-renderer-accessibility", "--new-window", htmlURL.absoluteString]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw E2EError.launchFailed(process.terminationStatus) }
        Thread.sleep(forTimeInterval: 2)
        let pid = try chromeComposerProcessID(profile: profile)
        try activateChromeComposer(pid: pid)
        return htmlURL
    }

    private static func activateChromeComposer(pid: Int32) throws {
        try runAppleScript("""
        tell application "System Events"
            set frontmost of first application process whose unix id is \(pid) to true
        end tell
        delay 0.5
        """)
    }

    private static func chromeComposerProcessID(profile: URL) throws -> Int32 {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", profile.path]
        process.standardOutput = output
        try process.run(); process.waitUntilExit()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let line = text.split(separator: "\n").first, let pid = Int32(line) else { throw E2EError.chromeProcessNotFound }
        return pid
    }

    private static func killChromeComposer(profile: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-f", profile.path]
        try? process.run(); process.waitUntilExit()
        try? FileManager.default.removeItem(at: profile)
    }

    private static func closeTextEditDocument(containing marker: String) throws {
        try runAppleScript("""
        tell application "TextEdit"
            repeat with candidate in documents
                if text of candidate contains \(appleScriptString(marker)) then
                    close candidate saving no
                    exit repeat
                end if
            end repeat
        end tell
        """)
    }

    private static func quitTextEditIfNoDocuments() throws {
        try runAppleScript("tell application \"TextEdit\"\nif (count of documents) is 0 then quit\nend tell")
    }

    private static func runAppleScript(_ script: String) throws {
        let process = Process(), input = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.standardInput = input; process.standardError = error
        try process.run()
        input.fileHandleForWriting.write(Data(script.utf8)); input.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw E2EError.appleScriptFailed(message)
        }
    }

    private static func appleScriptString(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private static func escapeHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private enum E2EError: Error { case launchFailed(Int32), appleScriptFailed(String), chromeProcessNotFound }
}

private struct ClipboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture() -> ClipboardSnapshot {
        let items = NSPasteboard.general.pasteboardItems?.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        } ?? []
        return ClipboardSnapshot(items: items)
    }

    func restore() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let restored = items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}
