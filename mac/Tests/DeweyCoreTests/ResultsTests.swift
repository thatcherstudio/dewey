import Foundation
import Testing
@testable import DeweyCore

private func decodeResult<T: Decodable>(_ line: String, as type: T.Type) throws -> T {
    guard case .result(let data) = DeweyEvent.parse(line) else {
        throw DeweyError.undecodable("not a result line")
    }
    return try DeweyEvent.decoder().decode(T.self, from: data)
}

/// Result lines copied from real `dewey … --json` runs on tests/test_e2e.py's build_mess() folder
/// (paths shortened; one batch added by hand, in the shape cli.status_data writes).
struct ResultsTests {
    @Test func decodesStatusOfAScannedFolder() throws {
        let line = #"""
        {"event": "result", "data": {"catalog": true, "root": "/Users/x/mess", "state": "/Users/x/mess/.dewey", "scan": {"id": 1, "started": "2026-11-17T20:56:32-05:00", "finished": "2026-11-17T20:56:32-05:00", "root": "/Users/x/mess", "files": 19, "bytes": 2089, "hashed": 19, "reused": 0, "units": 2, "missing": 0, "errors": 0}, "kinds": [{"kind": "bundle", "n": 1, "bytes": 8}, {"kind": "file", "n": 19, "bytes": 2089}, {"kind": "project", "n": 1, "bytes": 33}, {"kind": "symlink", "n": 1, "bytes": 16}], "duplicates": {"groups": 1, "copies": 2, "wasted": 120}, "top_types": [{"ext": ".jpg", "n": 1, "bytes": 749}, {"ext": ".docx", "n": 1, "bytes": 371}], "plans": [{"id": 1, "created": "2026-11-17T20:56:32-05:00", "decider": "none", "csv": "/Users/x/mess/.dewey/plan-1.csv", "report": "/Users/x/mess/.dewey/report-1.md", "summary": {"auto": {"n": 7, "bytes": 393}, "review": {"n": 0, "bytes": 0}, "skip": {"n": 0, "bytes": 0}, "duplicate": {"n": 1, "bytes": 60}, "folder": {"n": 4, "bytes": 198}}}], "batches": [{"batch": "20261117-210000-p1", "moves": 7, "undone": 0, "plan_id": 1, "moved_at": "2026-11-17T21:00:00-05:00"}], "undoable": "20261117-210000-p1", "labels": [], "errors": [{"path": "locked.pdf", "error": "PermissionError: denied"}]}}
        """#
        let s = try decodeResult(line, as: FolderStatus.self)
        #expect(s.catalog)
        #expect(s.scan?.files == 19)
        #expect(s.scan?.bytes == 2089)
        #expect(s.count("file") == 19)
        #expect(s.count("bundle") + s.count("project") == 2)
        #expect(s.count("cloud") == 0)
        #expect(s.duplicates == FolderStatus.Duplicates(groups: 1, copies: 2, wasted: 120))
        #expect(s.topTypes.map(\.ext) == [".jpg", ".docx"])
        #expect(s.latestPlan?.id == 1)
        #expect(s.latestPlan?.summary.auto == Bucket(n: 7, bytes: 393))
        #expect(s.latestPlan?.summary.folder.n == 4)
        #expect(s.batches.first?.planId == 1)
        #expect(s.batches.first?.movedAt == "2026-11-17T21:00:00-05:00")
        #expect(s.undoable == "20261117-210000-p1")
        #expect(s.errors == [PathError(path: "locked.pdf", error: "PermissionError: denied")])
    }

    @Test func aFolderNeverScannedIsNotAnError() throws {
        let line = #"{"event": "result", "data": {"catalog": false, "root": "/Users/x/new", "state": "/Users/x/new/.dewey"}}"#
        let s = try decodeResult(line, as: FolderStatus.self)
        #expect(!s.catalog)
        #expect(s.scan == nil)
        #expect(s.plans.isEmpty)
        #expect(s.latestPlan == nil)
        #expect(s.duplicates.copies == 0)
        #expect(s.decider == nil)  // dewey before 0.2.1 doesn't say
    }

    @Test func statusSaysWhichModelTheFolderAsks() throws {
        let line = #"{"event": "result", "data": {"catalog": false, "root": "/Users/x/new", "state": "/Users/x/new/.dewey", "decider": {"backend": "systemone", "url": "http://127.0.0.1:8000", "model": "english"}}}"#
        let s = try decodeResult(line, as: FolderStatus.self)
        #expect(s.decider == .init(backend: "systemone", url: "http://127.0.0.1:8000", model: "english"))
    }

    /// The app runs one Laya; a folder's own settings can name another model. Which is it?
    @Test func aFoldersModelIsTheAppsLayaOnlyWhenTheAddressesReachOneServer() throws {
        let app = try #require(URL(string: "http://127.0.0.1:8000"))
        func source(_ url: String, _ backend: String = "systemone") -> ModelSource {
            ModelSource(backend: backend, url: url, appLaya: app)
        }
        // every way of writing this Mac and that port is the app's Laya
        for same in ["http://127.0.0.1:8000", "http://localhost:8000", "http://127.0.0.1:8000/", " HTTP://LOCALHOST:8000 ",
                     "http://[::1]:8000"] {
            #expect(source(same) == .appLaya, "\(same)")
            #expect(source(same).isAppLaya)
        }
        // the usual mix-up: the app's Laya moved to another port, the folder still says 8000 (or the reverse)
        #expect(source("http://127.0.0.1:8001") == .otherLaya("127.0.0.1:8001"))
        #expect(ModelSource(backend: "systemone", url: "http://127.0.0.1:8000",
                            appLaya: try #require(URL(string: "http://127.0.0.1:8001"))) == .otherLaya("127.0.0.1:8000"))
        #expect(source("http://192.168.1.20:8000") == .otherLaya("192.168.1.20:8000"))
        #expect(source("https://127.0.0.1:8000") == .otherLaya("127.0.0.1:8000"))
        #expect(source("https://laya.example.com/team") == .otherLaya("laya.example.com"))
        #expect(source("http://127.0.0.1") == .otherLaya("127.0.0.1"))  // port 80
        #expect(source("not a url") == .otherLaya("not a url"))
        // a chat model or no model is never Laya, whatever the address says
        #expect(source("http://127.0.0.1:8080", "chat") == .chat("127.0.0.1:8080"))
        #expect(source("http://127.0.0.1:8000", "chat") == .chat("127.0.0.1:8000"))
        #expect(source("http://127.0.0.1:8000", "none") == .rulesOnly)
        #expect(!source("http://127.0.0.1:8000", "none").isAppLaya)
    }

    @Test func anInterruptedPlanHasAnEmptySummary() throws {
        let data = Data(#"{"id": 3, "created": "2026-11-17T20:56:32-05:00", "decider": "systemone:english", "csv": null, "report": null, "summary": {}}"#.utf8)
        let p = try DeweyEvent.decoder().decode(FolderStatus.Plan.self, from: data)
        #expect(p.summary == PlanSummary())
        #expect(p.csv == nil)
    }

    @Test func decodesScanAndPlanResults() throws {
        let scan = try decodeResult(#"{"event": "result", "data": {"scan_id": 2, "files": 19, "bytes": 2089, "hashed": 0, "reused": 19, "units": 2, "cloud": 0, "missing": 0, "errors": 1, "error_items": [{"path": "a.pdf", "error": "boom"}]}}"#,
                                    as: ScanResult.self)
        #expect(scan.scanId == 2)
        #expect(scan.reused == 19)
        #expect(scan.errorItems.first?.path == "a.pdf")

        let plan = try decodeResult(#"{"event": "result", "data": {"plan_id": 2, "csv": "/x/.dewey/plan-2.csv", "report": "/x/.dewey/report-2.md", "summary": {"auto": {"n": 7, "bytes": 393}, "review": {"n": 0, "bytes": 0}, "skip": {"n": 0, "bytes": 0}, "duplicate": {"n": 1, "bytes": 60}, "folder": {"n": 4, "bytes": 198}}}}"#,
                                    as: PlanResult.self)
        #expect(plan.planId == 2)
        #expect(plan.summary.duplicate == Bucket(n: 1, bytes: 60))
    }

    @Test func parsesDeweyTimestamps() throws {
        let d = try #require(DeweyDate.parse("2026-11-17T20:56:32-05:00"))
        #expect(d == Date(timeIntervalSince1970: 1_794_966_992))
        #expect(DeweyDate.parse(nil) == nil)
        #expect(DeweyDate.parse("yesterday") == nil)
    }
}
