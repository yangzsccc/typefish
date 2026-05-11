import AppKit
import XCTest
@testable import TypeFish

final class ContextSnapshotE2ETests: XCTestCase {
    func testClipboardSnapshotCapturesFrontmostTextEditDocument() throws {
        guard ProcessInfo.processInfo.environment["TYPEFISH_RUN_E2E"] == "1" else {
            throw XCTSkip("Set TYPEFISH_RUN_E2E=1 to run the focus/clipboard E2E snapshot test.")
        }

        let original = "所以我觉得最好的coding工具是Cloud Code，不是OpenCloud。"
        let edited = "所以我觉得最好的coding工具是Claude Code，不是OpenCloud。"
        let textEditWasRunning = Self.isTextEditRunning()
        try Self.openTextEditDocument(with: edited)
        defer {
            try? Self.closeTextEditDocument(containing: edited)
            if !textEditWasRunning {
                try? Self.quitTextEditIfNoDocuments()
            }
        }

        let result = EditTracker.evaluateBeforeSendSnapshotForTesting(original: original)
        XCTAssertEqual(result.snapshot, edited)
        XCTAssertTrue(result.shouldAnalyze)
    }

    func testClipboardSnapshotCapturesChromeContentEditableComposer() throws {
        guard ProcessInfo.processInfo.environment["TYPEFISH_RUN_E2E"] == "1" else {
            throw XCTSkip("Set TYPEFISH_RUN_E2E=1 to run the focus/clipboard E2E snapshot test.")
        }

        let chromePath = try Self.chromeAppPath()
        let original = "那现在到当下，我觉得最好的coding agent是Cloud Code还是OpenCloud？"
        let edited = "那现在到当下，我觉得最好的coding agent是Claude Code还是OpenCloud？"
        let profile = Self.chromeProfileURL()
        try Self.openChromeComposer(appPath: chromePath, profile: profile, text: edited)
        defer {
            Self.killChromeComposer(profile: profile)
        }

        PasteService.saveFrontmostApp()
        let result = EditTracker.evaluateBeforeSendSnapshotForTesting(original: original)
        XCTAssertEqual(result.snapshot, edited)
        XCTAssertTrue(result.shouldAnalyze)
    }

    private static func openTextEditDocument(with text: String) throws {
        try launchTextEdit()
        try runAppleScript("""
        tell application "TextEdit"
            activate
            make new document with properties {text:\(appleScriptString(text))}
        end tell
        delay 0.8
        """)
    }

    private static func launchTextEdit() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "TextEdit"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw E2EError.launchFailed(process.terminationStatus)
        }
        Thread.sleep(forTimeInterval: 1.0)
    }

    private static func isTextEditRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").isEmpty
    }

    private static func chromeAppPath() throws -> String {
        let candidates = [
            "/Applications/Google Chrome.app",
            "/Applications/Google Chrome.app.app"
        ]
        if let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return path
        }
        throw XCTSkip("Google Chrome is not installed.")
    }

    private static func chromeProfileURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("typefish-e2e-chrome-profile")
    }

    private static func openChromeComposer(appPath: String, profile: URL, text: String) throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: profile)
        try fileManager.createDirectory(at: profile, withIntermediateDirectories: true)

        let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <title>TypeFish E2E Composer</title>
          <style>
            body { font: 16px -apple-system, BlinkMacSystemFont, sans-serif; margin: 40px; }
            #composer {
              width: 760px;
              min-height: 96px;
              border: 1px solid #999;
              border-radius: 8px;
              padding: 12px;
              white-space: pre-wrap;
              outline: none;
            }
          </style>
        </head>
        <body>
          <div id="composer" role="textbox" contenteditable="true">\(escapeHTML(text))</div>
          <script>
            const composer = document.getElementById('composer');
            function focusComposer() {
              composer.focus();
              const range = document.createRange();
              range.selectNodeContents(composer);
              range.collapse(false);
              const selection = window.getSelection();
              selection.removeAllRanges();
              selection.addRange(range);
            }
            window.addEventListener('load', () => setTimeout(focusComposer, 250));
            document.addEventListener('keydown', event => {
              if (event.key === 'Enter') {
                event.preventDefault();
                document.title = 'TypeFish E2E Composer Sent';
              }
            });
          </script>
        </body>
        </html>
        """

        let htmlURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("typefish-e2e-composer.html")
        try html.write(to: htmlURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "-na", appPath,
            "--args",
            "--user-data-dir=\(profile.path)",
            "--no-first-run",
            "--disable-default-apps",
            "--new-window",
            htmlURL.absoluteString
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw E2EError.launchFailed(process.terminationStatus)
        }

        Thread.sleep(forTimeInterval: 2.0)
    }

    private static func killChromeComposer(profile: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-f", profile.path]
        try? process.run()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: profile)
    }

    private static func closeTextEditDocument(containing text: String) throws {
        try runAppleScript("""
        tell application "TextEdit"
            repeat with candidate in documents
                if text of candidate contains \(appleScriptString(text)) then
                    close candidate saving no
                    exit repeat
                end if
            end repeat
        end tell
        """)
    }

    private static func quitTextEditIfNoDocuments() throws {
        try runAppleScript("""
        tell application "TextEdit"
            if (count of documents) is 0 then quit
        end tell
        """)
    }

    private static func runAppleScript(_ script: String) throws {
        let process = Process()
        let input = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.standardInput = input
        process.standardError = error

        try process.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorText = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw E2EError.appleScriptFailed(errorText)
        }
    }

    private static func appleScriptString(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private enum E2EError: Error {
        case launchFailed(Int32)
        case appleScriptFailed(String)
    }
}
