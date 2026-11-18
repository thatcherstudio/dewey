import Foundation
import Observation

/// One dewey command with a progress screen: Move (`apply`) and Undo. It runs once; Cancel is
/// SIGINT, so a move stops after the file in hand and the batch so far stays undoable.
@MainActor @Observable
public final class CommandRun<Value: Decodable & Sendable> {
    public enum State: Sendable {
        case running
        case finished(Value)
        case failed(DeweyError)
        /// Cancelled. `batch` names the moves made so far, to undo them.
        case stopped(batch: String?)
    }

    public let arguments: [String]
    public private(set) var state: State = .running
    public private(set) var progress: RunProgress
    public private(set) var startedAt = Date()
    public private(set) var endedAt: Date?
    /// Called once, when the run ends (finished, failed or stopped).
    @ObservationIgnored public var onEnd: (@MainActor (CommandRun<Value>) -> Void)?

    @ObservationIgnored private let cli: DeweyCLI
    @ObservationIgnored private let phaseIds: [String]
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(cli: DeweyCLI, arguments: [String], phases: [String]) {
        self.cli = cli
        self.arguments = arguments
        self.phaseIds = phases
        self.progress = RunProgress(phases: phases)
    }

    public var isActive: Bool {
        if case .running = state { return true }
        return false
    }

    public var value: Value? {
        if case .finished(let v) = state { return v }
        return nil
    }

    public func start() {
        guard task == nil else { return }
        startedAt = .now
        task = Task { await self.perform() }
    }

    public func cancel() { task?.cancel() }

    /// Wait for the run to end (for tests and for quitting).
    public func wait() async { await task?.value }

    private func perform() async {
        do {
            try Task.checkCancellation()
            let v = try await cli.run(arguments, as: Value.self) { e in await self.receive(e) }
            progress.finish(phaseIds, ok: true)
            state = .finished(v)
        } catch {
            progress.finish(phaseIds, ok: false)
            if case DeweyError.interrupted(let batch) = error {
                state = .stopped(batch: batch)
            } else if error is CancellationError {
                state = .stopped(batch: nil)
            } else {
                state = .failed(error as? DeweyError ?? .launch(error.localizedDescription))
            }
        }
        endedAt = .now
        onEnd?(self)
    }

    private func receive(_ event: DeweyEvent) {
        progress.apply(event)
    }
}
