import XCTest
@testable import TypeFish

final class DictionaryTests: XCTestCase {
    func testLegacyDictionaryDecodesWithoutMetadata() throws {
        let json = """
        {
          "hints": ["Supabase"],
          "replacements": { "Chat GBT": "ChatGPT" },
          "vocabulary": ["pgvector"]
        }
        """

        let dict = try JSONDecoder().decode(CustomDictionary.self, from: Data(json.utf8))

        XCTAssertEqual(dict.hints, ["Supabase"])
        XCTAssertEqual(dict.replacements["Chat GBT"], "ChatGPT")
        XCTAssertEqual(dict.vocabulary, ["pgvector"])
        XCTAssertEqual(dict.metadata(for: "Chat GBT").source, .imported)
    }

    func testReplacementMetadataTracksManualAndAutoLearnedSources() throws {
        var dict = CustomDictionary()

        dict.addReplacement(wrong: "Chat GBT", right: "ChatGPT", source: .manual, persist: false)
        dict.addReplacement(wrong: "面金", right: "面经", source: .autoLearned, persist: false)

        XCTAssertEqual(dict.metadata(for: "Chat GBT").source, .manual)
        XCTAssertEqual(dict.metadata(for: "面金").source, .autoLearned)
        XCTAssertNotNil(dict.metadata(for: "Chat GBT").createdAt)
        XCTAssertNotNil(dict.metadata(for: "面金").updatedAt)
    }

    func testUpdatingAndRemovingReplacementMaintainsMetadata() {
        var dict = CustomDictionary()
        dict.addReplacement(wrong: "Chat GBT", right: "ChatGPT", source: .manual, persist: false)

        dict.updateReplacement(oldWrong: "Chat GBT", wrong: "Chat GPT", right: "ChatGPT", source: .manual, persist: false)

        XCTAssertNil(dict.replacements["Chat GBT"])
        XCTAssertEqual(dict.replacements["Chat GPT"], "ChatGPT")
        XCTAssertEqual(dict.metadata(for: "Chat GPT").source, .manual)

        dict.removeReplacement("Chat GPT", persist: false)

        XCTAssertNil(dict.replacements["Chat GPT"])
        XCTAssertEqual(dict.replacementMetadata["Chat GPT"], nil)
    }

    func testLatinReplacementsUseWordBoundaries() {
        var dict = CustomDictionary()
        dict.addReplacement(wrong: "O3", right: "OAuth", source: .manual, persist: false)
        dict.addReplacement(wrong: "Claw", right: "CL", source: .manual, persist: false)

        let output = dict.applyReplacements("O365 uses O3, but OpenClaw should stay OpenClaw and CO3 should stay CO3.")

        XCTAssertEqual(output, "O365 uses OAuth, but OpenClaw should stay OpenClaw and CO3 should stay CO3.")
    }

    func testCJKReplacementsStillUseExactSubstringMatching() {
        var dict = CustomDictionary()
        dict.addReplacement(wrong: "面金", right: "面经", source: .autoLearned, persist: false)

        XCTAssertEqual(dict.applyReplacements("这个面金很有用"), "这个面经很有用")
    }

    func testHintsAndVocabularyCanBeUpdatedAndRemoved() {
        var dict = CustomDictionary()
        dict.addHint("Chat GBT", persist: false)
        dict.updateHint(oldValue: "Chat GBT", newValue: "ChatGPT", persist: false)
        dict.addVocabulary("pg vector", persist: false)
        dict.updateVocabulary(oldValue: "pg vector", newValue: "pgvector", persist: false)

        XCTAssertEqual(dict.hints, ["ChatGPT"])
        XCTAssertEqual(dict.vocabulary, ["pgvector"])

        dict.removeHint("ChatGPT", persist: false)
        dict.removeVocabulary("pgvector", persist: false)

        XCTAssertTrue(dict.hints.isEmpty)
        XCTAssertTrue(dict.vocabulary.isEmpty)
    }
}
