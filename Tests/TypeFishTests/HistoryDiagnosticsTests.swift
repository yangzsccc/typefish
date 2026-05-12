import XCTest
@testable import TypeFish

final class HistoryDiagnosticsTests: XCTestCase {
    func testHistoryParserReturnsNewestValidEntriesFirst() {
        let content = """
        {"audio_file":"first.wav","field_context":"Already typed note","mode":"transcribe","polished":"first polished","polisher_model":"openai/gpt-oss-120b","timestamp":"2026-05-11T18:30:02Z","upload_file":"first.m4a","whisper_model":"whisper-large-v3","whisper_raw":"first raw"}
        not json
        {"audio_file":"second.wav","field_context":"","mode":"command","polished":"second polished","polisher_model":"llama-3.3-70b-versatile","timestamp":"2026-05-11T18:31:02Z","upload_file":"","whisper_model":"whisper-large-v3","whisper_raw":"second raw"}
        """

        let entries = TranscriptionLogger.parseHistory(from: content, limit: 5)

        XCTAssertEqual(entries.map(\.polished), ["second polished", "first polished"])
        XCTAssertEqual(entries[0].displayMode, "Command")
        XCTAssertEqual(entries[0].preview, "second polished")
        XCTAssertEqual(entries[1].contextPreview, "Already typed note")
        XCTAssertEqual(entries[1].audioFile, "first.wav")
    }

    func testHistoryParserUsesRawTextWhenPolishedTextIsMissing() {
        let content = """
        {"timestamp":"2026-05-11T18:30:02Z","mode":"translate","whisper_raw":"raw fallback","polished":"","whisper_model":"whisper-large-v3","polisher_model":"openai/gpt-oss-120b"}
        """

        let entries = TranscriptionLogger.parseHistory(from: content, limit: 5)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].displayMode, "Translate")
        XCTAssertEqual(entries[0].preview, "raw fallback")
    }

    func testMetricsAnalyzerComputesRecentDiagnostics() throws {
        let now = ISO8601DateFormatter().date(from: "2026-05-12T03:30:00Z")!
        let content = """
        {"audio_kb":100,"mode":"transcribe","ok":true,"polish_ms":400,"t":"2026-05-12T03:20:00Z","total_ms":1200,"whisper_ms":700}
        {"audio_kb":80,"err":"no_speech","mode":"transcribe","ok":false,"polish_ms":0,"t":"2026-05-12T03:21:00Z","total_ms":150,"whisper_ms":0}
        {"audio_kb":50,"mode":"transcribe","ok":true,"polish_ms":100,"t":"2026-05-10T03:21:00Z","total_ms":700,"whisper_ms":500}
        """

        let stats = MetricsLogger.analyze(content: content, now: now, hours: 24)

        XCTAssertEqual(stats.total, 2)
        XCTAssertEqual(stats.success, 1)
        XCTAssertEqual(stats.successRate, 50)
        XCTAssertEqual(stats.errors, ["no_speech": 1])
        XCTAssertEqual(stats.avgWhisperMs, 700)
        XCTAssertEqual(stats.avgPolishMs, 400)
        XCTAssertEqual(stats.avgTotalMs, 675)
    }
}
