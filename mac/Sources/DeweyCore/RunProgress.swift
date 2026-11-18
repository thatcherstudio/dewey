import Foundation

/// Folds a run's events into one row per phase (Walking, Hashing, Deciding…) plus its log lines,
/// for a progress screen.
///
/// dewey doesn't always close a phase: with nothing new to hash it opens "Hashing" at 0 of 0 and
/// moves on. So a phase also counts as done when a later phase starts or its command succeeds.
public struct RunProgress: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case waiting
        case running(ProgressUpdate)
        /// nil: the phase ended without a progress event of its own.
        case done(ProgressUpdate?)
        /// Its command finished without needing it (every decision was cached, rules covered everything…).
        case skipped
        case stopped(ProgressUpdate?)
    }

    public struct Phase: Sendable, Equatable, Identifiable {
        public var id: String
        public var label: String
        public var state: State

        public var fraction: Double? {
            switch state {
            case .running(let p): p.fraction
            case .done: 1
            case .waiting, .skipped: 0
            case .stopped(let p): p?.fraction ?? 0
            }
        }
    }

    public static let labels = ["walk": "Walking", "hash": "Hashing", "decide": "Deciding",
                                "move": "Moving", "undo": "Undoing"]
    public static let logLimit = 2000

    public private(set) var phases: [Phase]
    public private(set) var log: [String] = []

    /// `phases` are shown as waiting from the start, so the screen shows what's coming.
    public init(phases ids: [String]) {
        phases = ids.map { Phase(id: $0, label: Self.labels[$0] ?? $0.capitalized, state: .waiting) }
    }

    public func phase(_ id: String) -> Phase? { phases.first { $0.id == id } }

    public mutating func apply(_ event: DeweyEvent) {
        switch event {
        case .progress(let p): advance(p)
        case .log(let text): appendLog(text)
        case .unreadable(let line): appendLog(line)
        case .result, .error, .interrupted: break  // the caller shows the outcome
        }
    }

    /// A command ended. Its phases still running are done (or stopped, if it failed), and the ones
    /// that never started weren't needed.
    public mutating func finish(_ ids: [String], ok: Bool) {
        for i in phases.indices where ids.contains(phases[i].id) {
            switch phases[i].state {
            case .running(let p): phases[i].state = ok ? .done(p) : .stopped(p)
            case .waiting: if ok { phases[i].state = .skipped }
            case .done, .skipped, .stopped: break
            }
        }
    }

    private mutating func advance(_ p: ProgressUpdate) {
        let i: Int
        if let found = phases.firstIndex(where: { $0.id == p.phase }) {
            i = found
        } else {
            phases.append(Phase(id: p.phase, label: p.label, state: .waiting))
            i = phases.count - 1
        }
        for j in phases.indices where j < i {
            switch phases[j].state {
            case .running(let q): phases[j].state = .done(q)
            case .waiting: phases[j].state = .skipped
            case .done, .skipped, .stopped: break
            }
        }
        phases[i].label = p.label
        phases[i].state = p.done ? .done(p) : .running(p)
    }

    private mutating func appendLog(_ text: String) {
        log.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }
}

/// Words for progress numbers, shared by every progress screen.
public enum ProgressText {
    /// `0:42`, `12:05`, `1:02:03`.
    public static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    public static func bytes(_ n: Int64) -> String {
        n.formatted(.byteCount(style: .file))
    }

    public static func count(_ n: Int) -> String { n.formatted() }

    static func rate(_ r: Double) -> String {
        r >= 100 ? Int(r.rounded()).formatted() : r.formatted(.number.precision(.fractionLength(1)))
    }

    /// The line under a phase's progress bar.
    public static func detail(_ phase: RunProgress.Phase) -> String {
        switch phase.state {
        case .waiting:
            return "Waiting"
        case .skipped:
            return "Not needed this time"
        case .running(let p):
            var parts: [String] = []
            if let total = p.total {
                parts.append("\(count(p.n)) of \(count(total)) \(p.unit)")
            } else {
                parts.append("\(count(p.n)) \(p.unit)")
            }
            if let tb = p.totalBytes, tb > 0 { parts.append("\(bytes(p.bytes)) of \(bytes(tb))") }
            if p.elapsed >= 1.5 {  // early rates are mostly startup time
                parts.append("\(rate(p.rate)) \(p.unit)/s")
                if p.bytes > 0, p.elapsed > 0 { parts.append("\(bytes(Int64(Double(p.bytes) / p.elapsed)))/s") }
            }
            if let eta = p.eta { parts.append("about \(clock(eta)) left") }
            if !p.extra.isEmpty { parts.append(p.extra) }
            return parts.joined(separator: " · ")
        case .done(let p):
            guard let p else { return "Done" }
            if p.total == 0 { return "Nothing new" }
            var text = "\(count(p.n)) \(p.unit)"
            if p.bytes > 0 { text += " (\(bytes(p.bytes)))" }
            return text + " in \(clock(p.elapsed))"
        case .stopped(let p):
            guard let p else { return "Stopped" }
            if let total = p.total { return "Stopped at \(count(p.n)) of \(count(total)) \(p.unit)" }
            return "Stopped at \(count(p.n)) \(p.unit)"
        }
    }
}
