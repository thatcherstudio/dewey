import Foundation
import Testing
@testable import DeweyCore

/// A stand-in `dewey` for scan and plan. FAKE_DECIDER=down makes plan fail like a stopped Laya;
/// FAKE_SLOW=scan makes scan hash until it gets SIGINT.
private let fakeDewey = #"""
#!/bin/sh
cmd="$1"
backend=model
for a in "$@"; do [ "$prev" = "--backend" ] && backend="$a"; prev="$a"; done
case "$cmd" in
  scan)
    echo '{"event": "progress", "phase": "walk", "label": "Walking", "unit": "entries", "n": 0, "total": null, "bytes": 0, "total_bytes": null, "rate": 0, "elapsed": 0, "eta": null, "extra": "", "done": false}'
    echo '{"event": "progress", "phase": "walk", "label": "Walking", "unit": "entries", "n": 3, "total": null, "bytes": 0, "total_bytes": null, "rate": 3, "elapsed": 0.1, "eta": null, "extra": "", "done": true}'
    echo '{"event": "progress", "phase": "hash", "label": "Hashing", "unit": "files", "n": 0, "total": 3, "bytes": 0, "total_bytes": 30, "rate": 0, "elapsed": 0, "eta": null, "extra": "", "done": false}'
    if [ "$FAKE_SLOW" = "scan" ]; then
      trap 'echo "{\"event\": \"interrupted\", \"batch\": null, \"message\": \"saved\"}"; exit 130' INT
      while :; do sleep 0.05; done
    fi
    echo '{"event": "log", "text": "Scan 1: 3 files"}'
    echo '{"event": "result", "data": {"scan_id": 1, "files": 3, "bytes": 30, "hashed": 3, "reused": 0, "units": 0, "cloud": 0, "missing": 0, "errors": 0, "error_items": []}}' ;;
  plan)
    if [ "$backend" = "none" ]; then
      echo '{"event": "log", "text": "rules only"}'
      echo '{"event": "result", "data": {"plan_id": 2, "csv": "/x/plan-2.csv", "report": "/x/report-2.md", "summary": {"auto": {"n": 1, "bytes": 10}}}}'
    elif [ "$FAKE_DECIDER" = "down" ]; then
      echo '{"event": "log", "text": "Decider FAILED: connection refused"}'
      echo '{"event": "error", "code": "decider", "message": "Start the decision model server"}'
      exit 1
    else
      echo '{"event": "progress", "phase": "decide", "label": "Deciding", "unit": "files", "n": 0, "total": 2, "bytes": 0, "total_bytes": null, "rate": 0, "elapsed": 0, "eta": null, "extra": "", "done": false}'
      echo '{"event": "progress", "phase": "decide", "label": "Deciding", "unit": "files", "n": 2, "total": 2, "bytes": 0, "total_bytes": null, "rate": 2, "elapsed": 1, "eta": null, "extra": "", "done": true}'
      echo '{"event": "result", "data": {"plan_id": 1, "csv": "/x/plan-1.csv", "report": "/x/report-1.md", "summary": {"auto": {"n": 2, "bytes": 20}, "review": {"n": 1, "bytes": 10}}}}'
    fi ;;
esac
"""#

private func fakeCLI(_ env: [String: String] = [:]) throws -> DeweyCLI {
    let dir = FileManager.default.temporaryDirectory.appending(path: "dewey-fake-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appending(path: "dewey")
    try fakeDewey.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return DeweyCLI(executable: url, environment: ProcessInfo.processInfo.environment.merging(env) { $1 })
}

@MainActor
private final class Flag {
    var on: Bool
    init(_ on: Bool) { self.on = on }
}

@MainActor @Suite(.timeLimit(.minutes(1)))
struct ScanPlanSessionTests {
    @Test func scansThenPlans() async throws {
        let s = ScanPlanSession(cli: try fakeCLI(), root: "/x")
        var ends = 0
        s.onEnd = { _ in ends += 1 }
        s.start()
        #expect(s.isActive)
        await s.wait()
        #expect(s.state == .finished)
        #expect(s.scan?.files == 3)
        #expect(s.plan?.planId == 1)
        #expect(s.plan?.summary.review.n == 1)
        #expect(!s.rulesOnly)
        #expect(s.endedAt != nil)
        #expect(ends == 1)
        let states = s.progress.phases.map(\.state)
        for state in states {
            guard case .done = state else {
                Issue.record("every phase should be done: \(states)")
                return
            }
        }
        #expect(s.progress.log == ["Scan 1: 3 files"])
    }

    @Test func aStoppedModelFailsThePlanAndRulesOnlyRetriesWithoutRescanning() async throws {
        let s = ScanPlanSession(cli: try fakeCLI(["FAKE_DECIDER": "down"]), root: "/x")
        s.start()
        await s.wait()
        #expect(s.state == .failed(.plan, .failed(code: "decider", message: "Start the decision model server")))
        #expect(s.needsModel)
        #expect(s.scan != nil)
        #expect(s.progress.phase("decide")?.state == .waiting)  // never started

        s.retryPlan(rulesOnly: true)
        #expect(s.state == .running(.plan))
        await s.wait()
        #expect(s.state == .finished)
        #expect(s.rulesOnly)
        #expect(s.plan?.planId == 2)  // the fake answers --backend none with plan 2
        #expect(s.progress.phase("decide")?.state == .skipped)
        #expect(s.progress.log.contains("rules only"))
        #expect(s.progress.log.filter { $0 == "Scan 1: 3 files" }.count == 1)  // scanned once
    }

    @Test func waitsForALoadingModelBeforePlanning() async throws {
        let loading = Flag(true)
        let s = ScanPlanSession(cli: try fakeCLI(), root: "/x", modelLoading: { loading.on })
        s.start()
        var sawWaiting = false
        for _ in 0..<200 {
            if case .waitingForModel = s.state { sawWaiting = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(sawWaiting)
        try await Task.sleep(for: .milliseconds(300))
        guard case .waitingForModel = s.state else {
            Issue.record("should still be waiting, is \(s.state)")
            return
        }
        loading.on = false
        await s.wait()
        #expect(s.state == .finished)
        #expect(s.plan?.planId == 1)
    }

    @Test func cancelStopsTheScanAndKeepsTheSessionRestartable() async throws {
        let s = ScanPlanSession(cli: try fakeCLI(["FAKE_SLOW": "scan"]), root: "/x")
        s.start()
        for _ in 0..<200 {
            if case .running = s.progress.phase("hash")?.state { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        s.cancel()
        await s.wait()
        #expect(s.state == .stopped)
        #expect(s.plan == nil)
        guard case .stopped = s.progress.phase("hash")?.state else {
            Issue.record("hash should show as stopped")
            return
        }
        #expect(s.progress.phase("decide")?.state == .waiting)
    }

    @Test func cancelWhileWaitingForTheModelStops() async throws {
        let s = ScanPlanSession(cli: try fakeCLI(), root: "/x", modelLoading: { true })
        s.start()
        for _ in 0..<200 {
            if case .waitingForModel = s.state { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        s.cancel()
        await s.wait()
        #expect(s.state == .stopped)
        #expect(s.scan != nil)
        #expect(s.plan == nil)
    }
}
