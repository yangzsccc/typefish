import Foundation

/// Owns one confirmed paste from its first field read through the last response.
@MainActor
final class EditLearningMonitor {
    typealias Reader = () -> AnchoredEditObservation
    typealias Classifier = (String) async -> String?
    typealias DecisionClassifier = (String) async -> SpellingDecision

    enum Completion {
        case decision(SpellingDecision)
        case unconfirmed
        case unchanged
        case cancelled
    }

    struct Timing {
        var sample: TimeInterval = 0.04
        var confirm: TimeInterval = 1.2
        var transientReadGrace: TimeInterval = 2
        var settle: TimeInterval = 1.6
        var idle: TimeInterval = 15
        var lifetime: TimeInterval = 75
    }

    var onActiveChange: ((Bool) -> Void)?
    private let timing: Timing
    private var task: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var generation = UUID()
    private var finalizeTime: TimeInterval?
    private var wakeRequested = false
    private var wakeWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var pendingObservations: [AnchoredEditObservation] = []
    private var focusLossRequested = false
    private let maximumPendingObservations = 64
    private var completionHandler: ((Completion) -> Void)?
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var isActive: Bool { task != nil }

    init(timing: Timing = Timing()) { self.timing = timing }

    func noteEnter() {
        if isActive { finalizeImmediately() }
    }

    func noteFocusLoss() {
        guard isActive, !focusLossRequested else { return }
        focusLossRequested = true
        finalizeImmediately()
    }

    func noteFieldChange(_ observation: AnchoredEditObservation) {
        guard isActive else { return }
        guard pendingObservations.last != observation else { return }
        if pendingObservations.count >= maximumPendingObservations {
            pendingObservations = [.composing]
        }
        pendingObservations.append(observation)
        wake()
    }

    private func finalizeImmediately() {
        finalizeTime = now
        wake()
    }

    private func wake() {
        if wakeWaiters.isEmpty {
            wakeRequested = true
            return
        }
        let waiting = Array(wakeWaiters.values)
        wakeWaiters.removeAll()
        waiting.forEach { $0.resume() }
    }

    func stop() {
        generation = UUID()
        expiryTask?.cancel()
        expiryTask = nil
        task?.cancel()
        if task != nil { onActiveChange?(false) }
        task = nil
        finalizeTime = nil
        pendingObservations.removeAll()
        focusLossRequested = false
        completionHandler = nil
        wake()
    }

    func finishAsCancelled() {
        completionHandler?(.cancelled)
        completionHandler = nil
        stop()
    }

    func start(original: String, confirm: @escaping () -> Reader?, classify: @escaping Classifier,
               learn: @escaping (String) -> Void) {
        startDeciding(original: original, confirm: confirm, classify: { value in
            if let term = await classify(value) { return .learn(term) }
            return .skip
        }, onCompletion: { result in
            if case .decision(.learn(let term)) = result { learn(term) }
        })
    }

    func startDeciding(original: String, confirm: @escaping () -> Reader?, classify: @escaping DecisionClassifier,
                       onCompletion: @escaping (Completion) -> Void) {
        stop()
        completionHandler = onCompletion
        let id = generation
        expiryTask = Task { [weak self, lifetime = timing.lifetime] in
            try? await Task.sleep(nanoseconds: UInt64(lifetime * 1_000_000_000))
            guard !Task.isCancelled, let self, self.generation == id else { return }
            self.finishAsCancelled()
        }
        onActiveChange?(true)
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == id { self.stop() }
            }
            let startedAt = self.now
            let result = await self.observe(original: original, startedAt: startedAt,
                                            confirm: confirm, classify: classify)
            guard self.generation == id, !Task.isCancelled else { return }
            self.completionHandler?(result)
            self.completionHandler = nil
            if case .decision(.learn(let term)) = result {
                Log.info("Edit learning: classifier accepted spelling")
                _ = term
            }
            if case .unconfirmed = result { Log.info("Edit learning skipped: insertion unconfirmed") }
            if case .unchanged = result { Log.info("Edit learning finished without a correction") }
            self.stop()
        }
    }

    private func observe(original: String, startedAt start: TimeInterval,
                         confirm: @escaping () -> Reader?, classify: @escaping DecisionClassifier) async -> Completion {
            var reader: Reader?
            repeat {
                reader = await Task.detached(priority: .utility) { confirm() }.value
                guard !Task.isCancelled else { return .cancelled }
                if reader == nil { await self.waitForSample() }
            } while reader == nil && self.now - start < self.timing.confirm && !Task.isCancelled
            guard let reader, self.now - start <= self.timing.confirm else {
                return .unconfirmed
            }
            Log.info("Edit learning: insertion confirmed")
            var attempted: String?
            var last = original
            var changedAt = self.now
            var transientReadStartedAt: TimeInterval?
            observationLoop: while !Task.isCancelled && self.now - start < self.timing.lifetime {
                let observation: AnchoredEditObservation
                if !self.pendingObservations.isEmpty {
                    observation = self.pendingObservations.removeFirst()
                } else {
                    observation = await Task.detached(priority: .utility) { reader() }.value
                }
                guard !Task.isCancelled else { return .cancelled }
                let submitted: Bool
                switch observation {
                case .temporarilyUnavailable:
                    let gapStart = transientReadStartedAt ?? self.now
                    transientReadStartedAt = gapStart
                    guard self.now - gapStart < self.timing.transientReadGrace else {
                        Log.info("Edit learning skipped: field stayed temporarily unavailable")
                        return .unchanged
                    }
                    await self.waitForSample()
                    continue
                case .unavailable:
                    guard self.focusLossRequested && last != original else {
                        Log.info("Edit learning skipped: destination or span unavailable")
                        return .unchanged
                    }
                    submitted = true
                case .composing:
                    transientReadStartedAt = nil
                    // Discard provisional and previously observed text until the IME commits.
                    last = original
                    attempted = nil
                    changedAt = self.now
                    self.finalizeTime = nil
                    await self.waitForSample()
                    continue
                case .cleared:
                    transientReadStartedAt = nil
                    guard self.recentFinalize, last != original else { return .unchanged }
                    submitted = true
                case .text(let text):
                    transientReadStartedAt = nil
                    if text != last {
                        last = text
                        attempted = nil
                        changedAt = self.now
                    }
                    submitted = self.recentFinalize
                }
                if self.focusLossRequested && last == original { return .unchanged }
                if last != original && attempted != last && (submitted || self.now - changedAt >= self.timing.settle) {
                    attempted = last
                    let finalizedSnapshot = submitted && last != original
                    let proposed = await classify(last)
                    guard !Task.isCancelled, self.now - start < self.timing.lifetime else { return .cancelled }
                    if self.pendingObservations.contains(where: { observation in
                        switch observation {
                        case .text(let text): return text != last
                        case .composing: return true
                        case .temporarilyUnavailable, .unavailable, .cleared: return false
                        }
                    }) {
                        continue observationLoop
                    }
                    if proposed != .skip {
                        // Recheck the destination even when Enter cleared the previous field value.
                        let deadline = min(start + self.timing.lifetime, self.now + self.timing.transientReadGrace)
                        var current: AnchoredEditObservation
                        repeat {
                            current = await Task.detached(priority: .utility) { reader() }.value
                            guard !Task.isCancelled else { return .cancelled }
                            if current != .temporarilyUnavailable { break }
                            if finalizedSnapshot { break }
                            await self.waitForSample()
                        } while self.now < deadline
                        guard !Task.isCancelled, self.now < start + self.timing.lifetime else { return .cancelled }
                        switch current {
                        case .text(let text) where text == last: break
                        case .cleared where submitted || finalizedSnapshot: break
                        case .composing:
                            if self.focusLossRequested { return .unchanged }
                            last = original
                            attempted = nil
                            changedAt = self.now
                            continue observationLoop
                        case .text, .cleared:
                            if self.focusLossRequested { return .unchanged }
                            changedAt = self.now
                            continue observationLoop
                        case .temporarilyUnavailable where finalizedSnapshot:
                            break
                        case .unavailable where finalizedSnapshot:
                            break
                        case .temporarilyUnavailable, .unavailable:
                            return .unchanged
                        }
                        return .decision(proposed)
                    }
                    if submitted { return .decision(.skip) }
                }
                if self.now - changedAt >= self.timing.idle { return .unchanged }
                await self.waitForSample()
            }
        return Task.isCancelled ? .cancelled : .unchanged
    }

    private var recentFinalize: Bool { finalizeTime.map { now - $0 < 1.5 } ?? false }

    private func waitForSample() async {
        if wakeRequested {
            wakeRequested = false
            return
        }
        let id = UUID()
        await withCheckedContinuation { continuation in
            wakeWaiters[id] = continuation
            Task { [weak self, delay = timing.sample] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self else { return }
                if let waiter = self.wakeWaiters.removeValue(forKey: id) { waiter.resume() }
            }
        }
    }
}
