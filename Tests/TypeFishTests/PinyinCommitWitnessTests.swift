import XCTest
@testable import TypeFish

final class PinyinCommitWitnessTests: XCTestCase {
    private let sourceID = PinyinCommitWitness.inputSourceID
    private let base = "请联系刘军岩"

    private func makeWitness() -> PinyinCommitWitness { PinyinCommitWitness() }
    private var anchor: (String, NSRange) -> String? {
        let region = AnchoredTextRegion(prefix: "", suffix: "", originalText: base)
        return { text, selection in region.candidate(in: text, selectedRange: selection) }
    }

    private func observe(
        _ witness: PinyinCommitWitness,
        text: String,
        caret: Int? = nil,
        selectionLength: Int = 0,
        sourceID: String? = PinyinCommitWitness.inputSourceID,
        marked: MarkedTextStatus = .unavailable,
        isProseMirror: Bool = true,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime,
        scan: PinyinCandidateScan
    ) -> AnchoredEditObservation? {
        let location = caret ?? (text as NSString).length
        return witness.observe(
            text: text,
            selection: NSRange(location: location, length: selectionLength),
            markedTextStatus: marked,
            inputSourceID: sourceID,
            targetIsProseMirror: isProseMirror,
            candidateScan: scan,
            monotonicNow: now,
            anchoredText: anchor
        )
    }

    func testTwoSyllablePinyinRequiresObservedCandidateThenExactCommittedReplacement() {
        let witness = makeWitness()
        let phonetic = "请联系刘jun yan"
        let committed = "请联系刘俊言"
        XCTAssertEqual(observe(witness, text: phonetic,
                               scan: PinyinCandidateScan(status: .visible, candidates: ["俊言", "君言"])), .composing)
        XCTAssertEqual(observe(witness, text: committed,
                               scan: .absent), .text(committed))
        XCTAssertEqual(observe(witness, text: committed, scan: .absent), .text(committed))
    }

    func testTwoSyllableCommitPreservesExactSurroundingSuffixAndCaret() {
        let witness = makeWitness()
        let phonetic = "请联系刘jun yan，明天"
        let committed = "请联系刘俊言，明天"
        let region = AnchoredTextRegion(prefix: "", suffix: "", originalText: base)
        let anchored: (String, NSRange) -> String? = { text, selection in
            region.candidate(in: text, selectedRange: selection)
        }
        let caret = ("请联系刘俊言" as NSString).length
        XCTAssertEqual(witness.observe(
            text: phonetic,
            selection: NSRange(location: ("请联系刘jun yan" as NSString).length, length: 0),
            markedTextStatus: .unavailable,
            inputSourceID: sourceID,
            targetIsProseMirror: true,
            candidateScan: PinyinCandidateScan(status: .visible, candidates: ["俊言"]),
            anchoredText: anchored
        ), .composing)
        XCTAssertEqual(witness.observe(
            text: committed,
            selection: NSRange(location: caret, length: 0),
            markedTextStatus: .unavailable,
            inputSourceID: sourceID,
            targetIsProseMirror: true,
            candidateScan: .absent,
            anchoredText: anchored
        ), .text(committed))
    }

    func testPinyinSelectionUnrelatedEditAndWrongSourceCannotProveCommit() {
        let selected = makeWitness()
        XCTAssertNil(observe(selected, text: "请联系刘jun", selectionLength: 1,
                             scan: PinyinCandidateScan(status: .visible, candidates: ["俊"])))
        XCTAssertFalse(selected.hasPendingEvidence)

        let unrelated = makeWitness()
        XCTAssertEqual(observe(unrelated, text: "请联系刘jun yan",
                               scan: PinyinCandidateScan(status: .visible, candidates: ["俊言"])), .composing)
        XCTAssertEqual(observe(unrelated, text: "请联系刘俊言啊", scan: .absent), .composing)

        let wrongSource = makeWitness()
        XCTAssertNil(observe(wrongSource, text: "请联系刘jun", sourceID: "com.apple.keylayout.US",
                             scan: PinyinCandidateScan(status: .visible, candidates: ["俊"])))
        XCTAssertFalse(wrongSource.hasPendingEvidence)
    }

    func testNoCandidateUnknownDialogOrListClosedWithoutSelectionNeverProvesCommit() {
        let noCandidate = makeWitness()
        XCTAssertEqual(observe(noCandidate, text: "请联系刘jun",
                               scan: .unavailable), .composing)
        XCTAssertNil(observe(noCandidate, text: "请联系刘俊", scan: .absent))

        let unknownDialog = makeWitness()
        XCTAssertEqual(observe(unknownDialog, text: "请联系刘jun",
                               scan: .unavailable), .composing)
        XCTAssertNil(observe(unknownDialog, text: "请联系刘俊", scan: .unavailable))

        let closed = makeWitness()
        XCTAssertEqual(observe(closed, text: "请联系刘jun",
                               scan: PinyinCandidateScan(status: .visible, candidates: ["俊"])), .composing)
        XCTAssertEqual(observe(closed, text: "请联系刘jun", scan: .absent), .composing)
        XCTAssertEqual(observe(closed, text: "请联系刘君", scan: .absent), .composing)
        let closeRace = makeWitness()
        XCTAssertEqual(observe(closeRace, text: "请联系刘jun",
                               scan: PinyinCandidateScan(status: .visible, candidates: ["俊"])), .composing)
        XCTAssertEqual(observe(closeRace, text: "请联系刘jun", scan: .absent), .composing)
        XCTAssertEqual(observe(closeRace, text: "请联系刘俊", scan: .absent), .text("请联系刘俊"))
    }

    func testNewSyllableReplacesCandidateEvidenceInsteadOfUnioningPages() {
        let witness = makeWitness()
        XCTAssertEqual(observe(witness, text: "请联系刘jun",
                               scan: PinyinCandidateScan(status: .visible, candidates: ["军", "君"])), .composing)
        XCTAssertEqual(observe(witness, text: "请联系刘jun yan",
                               scan: PinyinCandidateScan(status: .visible, candidates: ["俊言", "君言"])), .composing)
        XCTAssertEqual(observe(witness, text: "请联系刘俊言", scan: .absent), .text("请联系刘俊言"))

        let stale = makeWitness()
        XCTAssertEqual(observe(stale, text: "请联系刘jun",
                               scan: PinyinCandidateScan(status: .visible, candidates: ["军"])), .composing)
        XCTAssertEqual(observe(stale, text: "请联系刘jun yan",
                               scan: PinyinCandidateScan(status: .visible, candidates: ["俊言"])), .composing)
        XCTAssertEqual(observe(stale, text: "请联系刘军言", scan: .absent), .composing)
    }

    func testCanceledPreeditResetsAndNewCompositionAfterProofStartsFresh() {
        let witness = makeWitness()
        XCTAssertEqual(observe(witness, text: "请联系刘jun",
                               scan: PinyinCandidateScan(status: .visible, candidates: ["俊"])), .composing)
        XCTAssertEqual(observe(witness, text: base, scan: .absent), .composing)
        XCTAssertFalse(witness.hasPendingEvidence)

        XCTAssertEqual(observe(witness, text: "请联系刘jun yan",
                               scan: PinyinCandidateScan(status: .visible, candidates: ["俊言"])), .composing)
        XCTAssertEqual(observe(witness, text: "请联系刘俊言", scan: .absent), .text("请联系刘俊言"))
        XCTAssertEqual(observe(witness, text: "请联系刘俊jun",
                               scan: PinyinCandidateScan(status: .visible, candidates: ["俊"])), .composing)
        XCTAssertEqual(observe(witness, text: "请联系刘俊俊", scan: .absent), .text("请联系刘俊俊"))
    }

    func testProofResetsForMarkedRangeDirectKeyboardAndOtherIme() {
        let witness = makeWitness()
        XCTAssertNil(observe(witness, text: "请联系刘jun", marked: .present,
                             scan: PinyinCandidateScan(status: .visible, candidates: ["俊"])))
        XCTAssertFalse(witness.hasPendingEvidence)
        XCTAssertNil(observe(witness, text: "请联系刘jun", marked: .absent,
                             scan: PinyinCandidateScan(status: .visible, candidates: ["俊"])))
        XCTAssertNil(observe(witness, text: "请联系刘jun", isProseMirror: false,
                             scan: PinyinCandidateScan(status: .visible, candidates: ["俊"])))
    }

    func testSingleCandidateScanGapRetainsEvidenceOnlyWithinNonRefreshingGrace() {
        let witness = makeWitness()
        let pinyin = "请联系刘jun yan"
        let committed = "请联系刘俊言"
        XCTAssertEqual(observe(witness, text: pinyin, now: 10,
                               scan: PinyinCandidateScan(status: .visible, candidates: ["俊言"])), .composing)
        XCTAssertEqual(observe(witness, text: pinyin, now: 10.2, scan: .unavailable), .composing)
        XCTAssertTrue(witness.hasPendingEvidence)
        XCTAssertEqual(observe(witness, text: committed, now: 10.3, scan: .unavailable), .composing)
        XCTAssertEqual(observe(witness, text: committed, now: 10.4, scan: .absent), .text(committed))

        let expired = makeWitness()
        XCTAssertEqual(observe(expired, text: pinyin, now: 20,
                               scan: PinyinCandidateScan(status: .visible, candidates: ["俊言"])), .composing)
        XCTAssertEqual(observe(expired, text: pinyin, now: 20.4, scan: .unavailable), .composing)
        XCTAssertEqual(observe(expired, text: committed, now: 20.51, scan: .absent), .composing)
        XCTAssertFalse(expired.hasPendingEvidence)
        XCTAssertNil(observe(expired, text: committed, now: 20.6, scan: .absent))

        let changed = makeWitness()
        XCTAssertEqual(observe(changed, text: pinyin, now: 30,
                               scan: PinyinCandidateScan(status: .visible, candidates: ["俊言"])), .composing)
        XCTAssertEqual(observe(changed, text: "请联系刘jun Yan", now: 30.1, scan: .unavailable), .composing)
        XCTAssertFalse(changed.hasPendingEvidence)
    }

    func testHeldExactTextWaitsForAConfirmedAbsentListOnRecheck() {
        let witness = makeWitness()
        let pinyin = "请联系刘jun yan"
        let committed = "请联系刘俊言"
        XCTAssertEqual(observe(witness, text: pinyin, now: 40,
                               scan: PinyinCandidateScan(status: .visible, candidates: ["俊言"])), .composing)
        XCTAssertEqual(observe(witness, text: committed, now: 40.1, scan: .absent), .text(committed))
        XCTAssertEqual(observe(witness, text: committed, now: 40.2, scan: .unavailable), .composing)
        XCTAssertEqual(observe(witness, text: committed, now: 40.3, scan: .absent), .text(committed))
    }
}
