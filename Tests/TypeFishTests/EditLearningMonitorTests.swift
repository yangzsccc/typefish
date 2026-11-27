import XCTest
@testable import TypeFish

// The field reader runs on a utility queue just as the AX reader does in the app.
private final class SampleField {
    private let lock = NSLock()
    private var value: AnchoredEditObservation
    init(_ value: AnchoredEditObservation) { self.value = value }
    func read() -> AnchoredEditObservation { lock.withLock { value } }
    func set(_ new: AnchoredEditObservation) { lock.withLock { value = new } }
}

@MainActor
final class EditLearningMonitorTests: XCTestCase {
    private let timing = EditLearningMonitor.Timing(sample: 0.003, confirm: 0.030, settle: 0.015, idle: 0.080, lifetime: 0.22)
    private func wait(until condition: () -> Bool) async {
        let end = ProcessInfo.processInfo.systemUptime + 1.5
        while !condition() && ProcessInfo.processInfo.systemUptime < end {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(condition())
    }

    func testConfirmedStableEditCommitsOnceAndReleasesListener() async {
        let monitor = EditLearningMonitor(timing: timing)
        let field = SampleField(.text("Claude Code"))
        var active = [Bool](), results = [String]()
        monitor.onActiveChange = { active.append($0) }
        monitor.start(original: "Cloud Code", confirm: { field.read }, classify: { $0 }, learn: { results.append($0) })
        await wait { !monitor.isActive }
        XCTAssertEqual(results, ["Claude Code"])
        XCTAssertEqual(active, [true, false])
    }

    func testUnconfirmedIdleMovedAndComposingFieldsAreReleasedWithoutWriting() async {
        let monitor = EditLearningMonitor(timing: timing)
        let field = SampleField(.text("Cloud"))
        for state: AnchoredEditObservation? in [nil, .text("Cloud"), .unavailable, .composing, .cleared] {
            if let state { field.set(state) }
            monitor.start(original: "Cloud", confirm: { state == nil ? nil : field.read },
                          classify: { _ in XCTFail("Unexpected classifier call"); return nil },
                          learn: { _ in XCTFail("Unexpected dictionary write") })
            await wait { !monitor.isActive }
        }
    }

    func testRejectedIntermediateSpellingCanBeCorrectedAndNetworkFailureIsNotRetried() async {
        let monitor = EditLearningMonitor(timing: timing)
        let field = SampleField(.text("Clau"))
        var attempts = [String](), saved = [String]()
        monitor.start(original: "Cloud", confirm: { field.read }, classify: {
            attempts.append($0)
            return $0 == "Claude" ? $0 : nil
        }, learn: { saved.append($0) })
        await wait { attempts == ["Clau"] }
        field.set(.composing)
        try? await Task.sleep(nanoseconds: 12_000_000)
        field.set(.text("Claude"))
        await wait { !monitor.isActive }
        XCTAssertEqual(attempts, ["Clau", "Claude"])
        XCTAssertEqual(saved, ["Claude"])

        attempts.removeAll()
        monitor.start(original: "Cloud", confirm: { field.read }, classify: { attempts.append($0); return nil },
                      learn: { _ in XCTFail("Network failure persisted") })
        await wait { !monitor.isActive }
        XCTAssertEqual(attempts, ["Claude"])
    }

    func testDelayedFirstSessionCannotWriteAfterSecondSessionOrUndo() async {
        for changeSession in [true, false] {
            let monitor = EditLearningMonitor(timing: timing)
            let field = SampleField(.text("First"))
            var reply: CheckedContinuation<String?, Never>?
            var saved = [String]()
            monitor.start(original: "Firstt", confirm: { field.read }, classify: { _ in
                await withCheckedContinuation { reply = $0 }
            }, learn: { saved.append($0) })
            await wait { reply != nil }
            if changeSession {
                monitor.start(original: "Second", confirm: { { .text("Secondo") } },
                              classify: { $0 }, learn: { saved.append($0) })
            } else { field.set(.text("Firstt")) }
            reply?.resume(returning: "First")
            await wait { !monitor.isActive }
            XCTAssertEqual(saved, changeSession ? ["Secondo"] : [])
        }
    }

    func testSlowConfirmationCannotStartLearningAfterItsDeadlineOrAfterStop() async {
        for cancel in [false, true] {
            let monitor = EditLearningMonitor(timing: timing)
            let reads = SampleField(.text("waiting"))
            monitor.start(original: "Cloud", confirm: {
                reads.set(.text("started"))
                Thread.sleep(forTimeInterval: 0.06)
                return { .text("Claude") }
            }, classify: { _ in XCTFail("Late confirmation started a request"); return nil },
                          learn: { _ in XCTFail("Late confirmation saved a term") })
            await wait { reads.read() == .text("started") }
            if cancel { monitor.stop() }
            await wait { !monitor.isActive }
            try? await Task.sleep(nanoseconds: 65_000_000)
        }
    }

    func testDeadlineReleasesListenerEvenIfClassifierIgnoresCancellation() async {
        let monitor = EditLearningMonitor(timing: timing)
        var reply: CheckedContinuation<String?, Never>?
        monitor.start(original: "Cloud", confirm: { { .text("Claude") } }, classify: { _ in
            await withCheckedContinuation { reply = $0 }
        }, learn: { _ in XCTFail("Expired session wrote a term") })
        await wait { reply != nil }
        await wait { !monitor.isActive }
        reply?.resume(returning: "Claude")
        await Task.yield()
    }

    func testEnterOnlyFinalizesAnObservedEditInSameField() async {
        let field = SampleField(.text("Claude Code"))
        let monitor = EditLearningMonitor(timing: .init(sample: 0.003, confirm: 0.04, settle: 0.18, idle: 0.2, lifetime: 0.3))
        var result = [String]()
        monitor.start(original: "Cloud Code", confirm: { field.read }, classify: { $0 }, learn: { result.append($0) })
        try? await Task.sleep(nanoseconds: 35_000_000)
        monitor.noteEnter()
        field.set(.cleared)
        await wait { !monitor.isActive }
        XCTAssertEqual(result, ["Claude Code"])
    }
}
