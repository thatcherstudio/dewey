import Foundation
import Testing
@testable import DeweyCore

private func progress(_ phase: String, n: Int, total: Int?, bytes: Int64 = 0, totalBytes: Int64? = nil,
                      elapsed: Double = 0, eta: Double? = nil, done: Bool = false) -> DeweyEvent {
    .progress(ProgressUpdate(phase: phase, label: RunProgress.labels[phase] ?? phase, unit: phase == "walk" ? "entries" : "files",
                             n: n, total: total, bytes: bytes, totalBytes: totalBytes, rate: elapsed > 0 ? Double(n) / elapsed : 0,
                             elapsed: elapsed, eta: eta, extra: "", done: done))
}

struct RunProgressTests {
    @Test func phasesWaitUntilTheirFirstEvent() {
        let p = RunProgress(phases: ["walk", "hash", "decide"])
        #expect(p.phases.map(\.label) == ["Walking", "Hashing", "Deciding"])
        #expect(p.phases.allSatisfy { $0.state == .waiting })
    }

    @Test func aLaterPhaseClosesEarlierOnes() {
        var p = RunProgress(phases: ["walk", "hash", "decide"])
        p.apply(progress("walk", n: 5, total: nil))
        #expect(p.phase("walk")?.fraction == nil)  // no total: the bar is indeterminate
        // dewey with nothing new to hash opens "Hashing" at 0 of 0 and never closes it
        p.apply(progress("hash", n: 0, total: 0))
        p.apply(progress("decide", n: 1, total: 4))
        guard case .done(let walk) = p.phase("walk")?.state, case .done = p.phase("hash")?.state else {
            Issue.record("walk and hash should be done: \(p.phases)")
            return
        }
        #expect(walk?.n == 5)
        #expect(p.phase("decide")?.fraction == 0.25)
        #expect(ProgressText.detail(p.phase("hash")!) == "Nothing new")
    }

    @Test func aPhaseThatNeverStartsIsSkippedWhenItsCommandSucceeds() {
        var p = RunProgress(phases: ["walk", "hash", "decide"])
        p.apply(progress("walk", n: 3, total: nil, done: true))
        p.apply(progress("hash", n: 2, total: 2, done: true))
        p.finish(["decide"], ok: true)  // every decision was cached
        #expect(p.phase("decide")?.state == .skipped)
        #expect(p.phase("decide")?.fraction == 0)
    }

    @Test func aFailedCommandStopsItsRunningPhaseAndLeavesWaitingOnesWaiting() {
        var p = RunProgress(phases: ["walk", "hash", "decide"])
        p.apply(progress("walk", n: 3, total: nil, done: true))
        p.apply(progress("hash", n: 1, total: 4))
        p.finish(["walk", "hash"], ok: false)
        guard case .stopped(let h) = p.phase("hash")?.state else {
            Issue.record("hash should be stopped")
            return
        }
        #expect(h?.n == 1)
        #expect(ProgressText.detail(p.phase("hash")!) == "Stopped at 1 of 4 files")
        #expect(p.phase("decide")?.state == .waiting)
    }

    @Test func anUnknownPhaseIsAddedAtTheEnd() {
        var p = RunProgress(phases: ["walk"])
        p.apply(progress("move", n: 1, total: 2))
        #expect(p.phases.map(\.id) == ["walk", "move"])
        #expect(p.phase("walk")?.state == .skipped)
    }

    @Test func logKeepsLinesInOrderAndSplitsMultiline() {
        var p = RunProgress(phases: [])
        p.apply(.log("Scan 1: 19 files"))
        p.apply(.log("  report: /x/report-1.md\n  plan:   /x/plan-1.csv"))
        p.apply(.unreadable("Traceback"))
        #expect(p.log == ["Scan 1: 19 files", "  report: /x/report-1.md", "  plan:   /x/plan-1.csv", "Traceback"])
        for i in 0..<(RunProgress.logLimit + 10) { p.apply(.log("line \(i)")) }
        #expect(p.log.count == RunProgress.logLimit)
        #expect(p.log.last == "line \(RunProgress.logLimit + 9)")
    }

    @Test func detailLines() {
        var p = RunProgress(phases: ["hash"])
        p.apply(progress("hash", n: 1, total: 4, bytes: 500, totalBytes: 2000, elapsed: 0.5))
        #expect(ProgressText.detail(p.phases[0]) == "1 of 4 files · 500 bytes of 2 kB")  // no rate before 1.5 s
        p.apply(progress("hash", n: 2, total: 4, bytes: 1000, totalBytes: 2000, elapsed: 2, eta: 75))
        #expect(ProgressText.detail(p.phases[0]) == "2 of 4 files · 1 kB of 2 kB · 1.0 files/s · 500 bytes/s · about 1:15 left")
        p.apply(progress("hash", n: 4, total: 4, bytes: 2000, totalBytes: 2000, elapsed: 3.4, done: true))
        #expect(ProgressText.detail(p.phases[0]) == "4 files (2 kB) in 0:03")
    }

    @Test func clock() {
        #expect(ProgressText.clock(0) == "0:00")
        #expect(ProgressText.clock(42.4) == "0:42")
        #expect(ProgressText.clock(725) == "12:05")
        #expect(ProgressText.clock(3723) == "1:02:03")
        #expect(ProgressText.clock(-5) == "0:00")
    }
}

@MainActor
struct FolderStoreTests {
    private func store() -> (FolderStore, UserDefaults) {
        let name = "dewey-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return (FolderStore(defaults: d, key: "folders"), d)
    }

    @Test func addPutsNewestFirstWithoutDuplicates() {
        let (s, d) = store()
        s.add(URL(fileURLWithPath: "/Users/x/Downloads"))
        s.add(URL(fileURLWithPath: "/Users/x/Desktop/"))
        s.add(URL(fileURLWithPath: "/Users/x/Downloads/../Downloads"))
        #expect(s.paths == ["/Users/x/Downloads", "/Users/x/Desktop"])
        #expect(d.stringArray(forKey: "folders") == s.paths)
        #expect(FolderStore(defaults: d, key: "folders").paths == s.paths)  // survives a relaunch
    }

    @Test func normalizeResolvesSymlinksLikeDewey() {
        // /tmp is a symlink to /private/tmp; dewey's Path.resolve() sees one folder, so must we
        #expect(FolderStore.normalize(URL(fileURLWithPath: "/tmp")) == "/private/tmp")
        #expect(FolderStore.normalize(URL(fileURLWithPath: "/")) == "/")
    }

    @Test func removeAndMove() {
        let (s, _) = store()
        for p in ["/d", "/c", "/b", "/a"] { s.add(URL(fileURLWithPath: p)) }
        #expect(s.paths == ["/a", "/b", "/c", "/d"])
        s.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)  // drag /a below /c
        #expect(s.paths == ["/b", "/c", "/a", "/d"])
        s.move(fromOffsets: IndexSet([2, 3]), toOffset: 0)
        #expect(s.paths == ["/a", "/d", "/b", "/c"])
        s.remove("/d")
        #expect(s.paths == ["/a", "/b", "/c"])
    }
}

struct RootCheckTests {
    private func check(_ path: String) -> RootCheck { RootCheck.check(path, home: "/Users/someone") }

    private func refused(_ path: String) -> Bool {
        if case .refuse = check(path) { return true }
        return false
    }

    @Test func systemFoldersTheLibraryAndAnythingHoldingHomeAreRefused() {
        for p in ["/", "/Users", "/Users/someone/Library", "/Users/someone/Library/Application Support/App",
                  "/Users/someone/Library/Mobile Documents", "/Users/someone/Library/CloudStorage",
                  "/System/Library", "/Library/Fonts", "/Applications", "/usr/local/bin", "/private/etc",
                  "/private/tmp", "/private/var", "/Volumes"] {
            #expect(refused(p), "\(p)")
        }
    }

    @Test func ordinaryFoldersCloudDrivesAndOtherDisksAreFine() {
        for p in ["/Users/someone/Downloads", "/Users/someone/Documents/Library",
                  "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs",
                  "/Users/someone/Library/CloudStorage/Dropbox/Scans", "/Volumes/Backup", "/Volumes/Backup/Photos",
                  "/Users/Shared/Scans", "/private/tmp/scratch"] {
            #expect(check(p) == .ok, "\(p)")
        }
    }

    @Test func theHomeFolderAsksFirst() {
        guard case .confirm = check("/Users/someone") else {
            Issue.record("the home folder should ask before it is added")
            return
        }
    }
}
