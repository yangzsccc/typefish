import XCTest
@testable import TypeFish

final class DictionaryTests: XCTestCase {
    private func makeTemporaryDictionaryURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TypeFishDictionaryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("dictionary.json")
    }

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

    func testLearnedSpellingPhrasesHavePriorityInWhisperAndPolisherHints() {
        var dict = CustomDictionary(hints: ["manual term", "Cloud"])
        let learned = dict.addLearnedSpellingPreference("Claude Code", persist: false)

        XCTAssertNotNil(learned)
        XCTAssertEqual(dict.whisperPrompt(), "Spelling guide: Claude Code, manual term, Cloud")
        XCTAssertTrue(dict.polisherReference()?.contains("Claude Code") == true)
        XCTAssertNil(dict.addLearnedSpellingPreference("claude code", persist: false))
    }

    func testNewestLearnedSpellingAppearsFirstInPromptBudget() throws {
        var dict = CustomDictionary(hints: [String(repeating: "x", count: 860)])
        _ = dict.addLearnedSpellingPreference("older name", persist: false)
        _ = dict.addLearnedSpellingPreference("newer proper name", persist: false)

        let prompt = try XCTUnwrap(dict.whisperPrompt())

        XCTAssertTrue(prompt.hasPrefix("Spelling guide: newer proper name, older name"))
        XCTAssertLessThanOrEqual(prompt.count, 896)
    }

    func testWhisperPromptSkipsOversizedHintAndKeepsLaterShortHint() {
        let dict = CustomDictionary(hints: [String(repeating: "x", count: 900), "short hint"])

        XCTAssertEqual(dict.whisperPrompt(), "Spelling guide: short hint")
    }

    func testLearnedSpellingUndoIsConditionalAndIdempotentAfterReload() throws {
        let url = try makeTemporaryDictionaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var dict = CustomDictionary(hints: ["Manual Name"])
        let learned = try XCTUnwrap(dict.addLearnedSpellingPreference("Claude Code", persist: false))
        dict.save(to: url)

        var reloaded = CustomDictionary.load(from: url)
        XCTAssertTrue(reloaded.undoLearnedSpellingPreference(learned))
        XCTAssertEqual(reloaded.hints, ["Manual Name"])
        XCTAssertTrue(reloaded.undoLearnedSpellingPreference(learned))
        XCTAssertTrue(CustomDictionary.load(from: url).learnedSpellingPreferences.isEmpty)
    }

    func testAlternateStorageURLPersistsLaterAtomicMutations() throws {
        let url = try makeTemporaryDictionaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var dict = CustomDictionary()
        dict.save(to: url)
        dict.addLearnedSpellingPreference("Niamh")

        let loaded = CustomDictionary.load(from: url)
        XCTAssertEqual(loaded.learnedSpellingPreferences.map(\.phrase), ["Niamh"])
    }

    func testLearnedSpellingMutationRollsBackWhenAtomicSaveFails() throws {
        let url = try makeTemporaryDictionaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let blockingFile = url.deletingLastPathComponent().appendingPathComponent("not-a-directory")
        try Data("block".utf8).write(to: blockingFile)
        let blockedURL = blockingFile.appendingPathComponent("dictionary.json")

        var dict = CustomDictionary(storageURL: blockedURL)
        XCTAssertNil(dict.addLearnedSpellingPreference("Niamh"))
        XCTAssertTrue(dict.learnedSpellingPreferences.isEmpty)

        let existing = try XCTUnwrap(dict.addLearnedSpellingPreference("Aoife", persist: false))
        XCTAssertFalse(dict.undoLearnedSpellingPreference(existing))
        XCTAssertEqual(dict.learnedSpellingPreferences, [existing])

        XCTAssertNil(dict.updateLearnedSpellingPreference(existing, phrase: "Aoifee"))
        XCTAssertEqual(dict.learnedSpellingPreferences, [existing])
    }

    func testLearnedSpellingUndoPreservesChangedRecord() throws {
        let url = try makeTemporaryDictionaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var dict = CustomDictionary()
        let learned = try XCTUnwrap(dict.addLearnedSpellingPreference("Claude Code", persist: false))
        dict.learnedSpellingPreferences[0].phrase = "Claude Desktop"
        dict.save(to: url)

        var reloaded = CustomDictionary.load(from: url)
        XCTAssertFalse(reloaded.undoLearnedSpellingPreference(learned))
        XCTAssertEqual(reloaded.learnedSpellingPreferences.first?.phrase, "Claude Desktop")
    }

    func testUpdatingLearnedSpellingPreservesIdentityAndInvalidatesOldUndoToken() throws {
        var dict = CustomDictionary()
        let learned = try XCTUnwrap(dict.addLearnedSpellingPreference("Claude Code", persist: false))

        let updated = try XCTUnwrap(dict.updateLearnedSpellingPreference(learned, phrase: "Claude Desktop", persist: false))

        XCTAssertEqual(updated.id, learned.id)
        XCTAssertEqual(updated.phrase, "Claude Desktop")
        XCTAssertFalse(dict.undoLearnedSpellingPreference(learned, persist: false))
        XCTAssertTrue(dict.undoLearnedSpellingPreference(updated, persist: false))
    }

    func testLegacyAutoLearnedRulesMigrateWithoutChangingManualOrImportedRules() throws {
        let url = try makeTemporaryDictionaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var dict = CustomDictionary()
        dict.addReplacement(wrong: "Cloud", right: "Claude", source: .autoLearned, persist: false)
        dict.addReplacement(wrong: "Manual typo", right: "Manual phrase", source: .manual, persist: false)
        dict.replacements["Old typo"] = "Old phrase"
        let encoder = JSONEncoder()
        try encoder.encode(dict).write(to: url)

        let loaded = CustomDictionary.load(from: url)
        XCTAssertNil(loaded.replacements["Cloud"])
        XCTAssertEqual(loaded.replacements["Manual typo"], "Manual phrase")
        XCTAssertEqual(loaded.replacements["Old typo"], "Old phrase")
        XCTAssertEqual(loaded.metadata(for: "Old typo").source, .imported)
        XCTAssertTrue(loaded.learnedSpellingPreferences.contains { $0.phrase == "Claude" })
        XCTAssertEqual(loaded.applyReplacements("Google Cloud"), "Google Cloud")

        let loadedAgain = CustomDictionary.load(from: url)
        XCTAssertEqual(loadedAgain.learnedSpellingPreferences.count, 1)
    }
}
