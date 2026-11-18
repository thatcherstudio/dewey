import Foundation
import Observation

/// Scan & Plan for one folder: `dewey scan ROOT`, then `dewey plan ROOT`, with progress for a screen.
///
/// Two commands rather than `dewey run`, so that a plan that fails (the decision model isn't
/// running) can be retried without scanning again, and so the plan can wait for a Laya model that is
/// still loading instead of failing.
@MainActor @Observable
public final class ScanPlanSession {
    public enum Step: String, Sendable { case scan, plan }

    public enum State: Equatable, Sendable {
        case running(Step)
        /// Scanned; waiting for the Laya model to finish loading before planning.
        case waitingForModel(since: Date)
        case finished
        case failed(Step, DeweyError)
        /// Cancelled. Hashes and decisions made so far are saved, so the next run picks up from here.
        case stopped
    }

    static let scanPhases = ["walk", "hash"]
    static let planPhases = ["decide"]

    public let root: String
    public private(set) var state: State = .running(.scan)
    public private(set) var progress = RunProgress(phases: scanPhases + planPhases)
    public private(set) var scan: ScanResult?
    public private(set) var plan: PlanResult?
    /// The last plan was made with `--backend none` (rules and duplicates only).
    public private(set) var rulesOnly = false
    /// When the current (or last) run started: a retry starts the clock again.
    public private(set) var startedAt = Date()
    public private(set) var endedAt: Date?
    /// Called once each time the session stops being active (finished, failed or stopped).
    @ObservationIgnored public var onEnd: (@MainActor (ScanPlanSession) -> Void)?

    @ObservationIgnored private let cli: DeweyCLI
    @ObservationIgnored private let modelLoading: @MainActor () -> Bool
    @ObservationIgnored private var task: Task<Void, Never>?

    /// `modelLoading` says whether the Laya model is still starting up (the plan waits for it).
    public init(cli: DeweyCLI, root: String, modelLoading: @escaping @MainActor () -> Bool = { false }) {
        self.cli = cli
        self.root = root
        self.modelLoading = modelLoading
    }

    public var isActive: Bool {
        switch state {
        case .running, .waitingForModel: true
        case .finished, .failed, .stopped: false
        }
    }

    /// The plan failed because the decision model didn't answer.
    public var needsModel: Bool {
        if case .failed(.plan, .failed(code: "decider", message: _)) = state { return true }
        return false
    }

    public func start() {
        guard task == nil else { return }
        launch(scanFirst: true, rulesOnly: false)
    }

    /// Plan again without scanning, after a failed or stopped plan.
    public func retryPlan(rulesOnly: Bool) {
        guard !isActive, scan != nil else { return }
        launch(scanFirst: false, rulesOnly: rulesOnly)
    }

    /// Scan and plan again from the start.
    public func restart() {
        guard !isActive else { return }
        progress = RunProgress(phases: Self.scanPhases + Self.planPhases)
        scan = nil
        plan = nil
        launch(scanFirst: true, rulesOnly: false)
    }

    /// Like Ctrl-C: dewey stops after the item in hand and keeps everything done so far.
    public func cancel() { task?.cancel() }

    /// Wait for the current run to end (for tests and for quitting).
    public func wait() async { await task?.value }

    private func launch(scanFirst: Bool, rulesOnly: Bool) {
        self.rulesOnly = rulesOnly
        endedAt = nil
        startedAt = .now
        state = .running(scanFirst ? .scan : .plan)
        task = Task { await self.perform(scanFirst: scanFirst, rulesOnly: rulesOnly) }
    }

    private func perform(scanFirst: Bool, rulesOnly: Bool) async {
        if scanFirst {
            do {
                try Task.checkCancellation()
                scan = try await cli.run(["scan", root], as: ScanResult.self) { e in await self.receive(e) }
                progress.finish(Self.scanPhases, ok: true)
            } catch {
                return end(.scan, error)
            }
        }
        if !rulesOnly && modelLoading() {
            state = .waitingForModel(since: .now)
            while modelLoading() && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        state = .running(.plan)
        do {
            try Task.checkCancellation()
            plan = try await cli.run(["plan", root] + (rulesOnly ? ["--backend", "none"] : []),
                                     as: PlanResult.self) { e in await self.receive(e) }
            progress.finish(Self.planPhases, ok: true)
            state = .finished
            endedAt = .now
            onEnd?(self)
        } catch {
            end(.plan, error)
        }
    }

    private func end(_ step: Step, _ error: Error) {
        progress.finish(step == .scan ? Self.scanPhases : Self.planPhases, ok: false)
        if Task.isCancelled || error is CancellationError {
            state = .stopped
        } else if case DeweyError.interrupted = error {
            state = .stopped
        } else {
            state = .failed(step, error as? DeweyError ?? .launch(error.localizedDescription))
        }
        endedAt = .now
        onEnd?(self)
    }

    private func receive(_ event: DeweyEvent) {
        progress.apply(event)
    }
}
