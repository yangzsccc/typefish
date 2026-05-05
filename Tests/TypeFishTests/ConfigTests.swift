import XCTest
@testable import TypeFish

final class ConfigTests: XCTestCase {
    func testDefaultPolisherUsesGPTOSS120B() {
        XCTAssertEqual(AppConfig().polisherModel, "openai/gpt-oss-120b")
        XCTAssertEqual(AppConfig().whisperModel, "whisper-large-v3")
    }

    func testPartialConfigDecodesWithDefaults() throws {
        let data = """
        {
          "whisperModel": "whisper-large-v3",
          "polisherModel": "openai/gpt-oss-120b"
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertEqual(config.whisperModel, "whisper-large-v3")
        XCTAssertEqual(config.polisherModel, "openai/gpt-oss-120b")
        XCTAssertNil(config.whisperLanguage)
        XCTAssertEqual(config.audioCompressionBitrate, 64000)
        XCTAssertNil(config.preferredMicrophone)
    }
}
