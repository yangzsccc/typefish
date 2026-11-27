import Foundation

/// Owns one confirmed paste from its first field read through the last response.
@MainActor
final class EditLearningMonitor {
    typealias Reader = () -> AnchoredEditObservation
    typealias Classifier = (String) async -> String?

    struct Timing {
        var sample: TimeInterval = 0.15
        var confirm: TimeInterval = 1.2
        var settle: TimeInterval = 1.6
        var idle: TimeInterval = 15
        var lifetime: TimeInterval = 75
    }

    var onActiveChange: ((Bool) -> Void)?
    private let timing: Timing
    private var task: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var generation = UUID()
    private var enterTime: TimeInterval?
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var isActive: Bool { task != nil }

    init(timing: Timing = Timing()) { self.timing = timing }

    func noteEnter() {
        if isActive { enterTime = now }
    }

    func stop() {
        generation = UUID()
        expiryTask?.cancel()
        expiryTask = nil
        task?.cancel()
        if task != nil { onActiveChange?(false) }
        task = nil
        enterTime = nil
    }

    func start(original: String, confirm: @escaping () -> Reader?, classify: @escaping Classifier,
               learn: @escaping (String) -> Void) {
        stop()
        let id = generation
        expiryTask = Task { [weak self, lifetime = timing.lifetime] in
            try? await Task.sleep(nanoseconds: UInt64(lifetime * 1_000_000_000))
            guard !Task.isCancelled, let self, self.generation == id else { return }
            self.stop()
        }
        onActiveChange?(true)
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == id { self.stop() }
            }
            let start = self.now
            var reader: Reader?
            repeat {
                reader = await Task.detached(priority: .utility) { confirm() }.value
                guard self.generation == id, !Task.isCancelled else { return }
                if reader == nil { await self.waitForSample() }
            } while reader == nil && self.now - start < self.timing.confirm && !Task.isCancelled
            guard let reader, self.now - start <= self.timing.confirm else {
                Log.info("Edit learning skipped: insertion unconfirmed")
                return
            }
            Log.info("Edit learning: insertion confirmed")
            var attempted: String?
            var last = original
            var changedAt = self.now
            while self.generation == id && !Task.isCancelled && self.now - start < self.timing.lifetime {
                let observation = await Task.detached(priority: .utility) { reader() }.value
                guard self.generation == id, !Task.isCancelled else { return }
                let submitted: Bool
                switch observation {
                case .unavailable:
                    Log.info("Edit learning skipped: destination or span unavailable")
                    return
                case .composing:
                    // Discard provisional and previously observed text until the IME commits.
                    last = original
                    attempted = nil
                    changedAt = self.now
                    self.enterTime = nil
                    await self.waitForSample()
                    continue
                case .cleared:
                    guard self.recentEnter, last != original else { return }
                    submitted = true
                case .text(let text):
                    if text != last {
                        last = text
                        attempted = nil
                        changedAt = self.now
                    }
                    submitted = false
                }
                if last != original && attempted != last && (submitted || self.now - changedAt >= self.timing.settle) {
                    attempted = last
                    let proposed = await classify(last)
                    guard self.generation == id, !Task.isCancelled, self.now - start < self.timing.lifetime else { return }
                    if let proposed {
                        // Recheck the destination even when Enter cleared the previous field value.
                        let current = await Task.detached(priority: .utility) { reader() }.value
                        guard self.generation == id, !Task.isCancelled else { return }
                        switch current {
                        case .text(let text) where text == last: break
                        case .cleared where submitted || self.recentEnter: break
                        case .text, .composing:
                            changedAt = self.now
                            continue
                        default: return
                        }
                        learn(proposed)
                        return
                    }
                    if submitted { return }
                }
                if self.now - changedAt >= self.timing.idle { return }
                await self.waitForSample()
            }
        }
    }

    private var recentEnter: Bool { enterTime.map { now - $0 < 0.8 } ?? false }

    private func waitForSample() async {
        try? await Task.sleep(nanoseconds: UInt64(timing.sample * 1_000_000_000))
    }
}
