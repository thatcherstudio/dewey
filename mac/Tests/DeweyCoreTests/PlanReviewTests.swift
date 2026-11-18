import Foundation
import Testing
@testable import DeweyCore

/// A `dewey rows` result in the shape mover.plan_rows writes, with one row of each kind the table
/// has to show: a rule, a model guess to review, a skip, a whole folder, a row already edited in
/// Numbers, and a row apply refuses.
private let rowsJSON = #"""
{"plan_id": 3, "created": "2026-11-17T21:00:00-05:00", "decider": "systemone:english", "root": "/x", "dest_root": "/x",
 "csv": "/x/.dewey/plan-3.csv", "report": "/x/.dewey/report-3.md", "csv_sha256": "abc",
 "summary": {"auto": {"n": 1, "bytes": 300}},
 "categories": [{"key": "finance", "path": "Documents/Finance", "desc": "bills"},
                {"key": "work", "path": "Documents/Work", "desc": "job"},
                {"key": "code", "path": "Code", "desc": "source"},
                {"key": "other", "path": "", "desc": "anything else"}],
 "folder_kinds": [{"kind": "documents", "path": "Documents"}, {"kind": "mixed", "path": ""}],
 "auto_confidence": 0.85, "review_confidence": 0.5,
 "rows": [
  {"row": 1, "src": "setup.dmg", "action": "move", "size": 300, "status": "auto", "dst": "Installers/setup.dmg", "category": "rule:installer", "verdict": "move", "why": "", "in_csv": true, "edited": false, "planned": {"status": "auto", "dst": "Installers/setup.dmg", "category": "rule:installer"}, "confidence": 1.0, "decided_by": "rule:installer", "reason": "Installer", "alternatives": ""},
  {"row": 2, "src": "minutes.docx", "action": "move", "size": 20, "status": "review", "dst": "Documents/Work/minutes.docx", "category": "work", "verdict": "move", "why": "", "in_csv": true, "edited": false, "planned": {"status": "review", "dst": "Documents/Work/minutes.docx", "category": "work"}, "confidence": 0.7, "decided_by": "systemone:english", "reason": "Model: work at 0.70", "alternatives": "finance 0.2"},
  {"row": 3, "src": "a.py", "action": "move", "size": 10, "status": "skip", "dst": "Code/a.py", "category": "code", "verdict": "move", "why": "", "in_csv": true, "edited": false, "planned": {"status": "skip", "dst": "Code/a.py", "category": "code"}, "confidence": 0.4, "decided_by": "systemone:english", "reason": "Model: code at 0.40", "alternatives": ""},
  {"row": 4, "src": "Taxes", "action": "folder", "size": 900, "status": "review", "dst": "Documents/Taxes", "category": "documents", "verdict": "move", "why": "", "in_csv": true, "edited": false, "planned": {"status": "review", "dst": "Documents/Taxes", "category": "documents"}, "confidence": 1.0, "decided_by": "folder-kind", "reason": "Whole folder", "alternatives": ""},
  {"row": 5, "src": "bill.pdf", "action": "move", "size": 50, "status": "auto", "dst": "Documents/Finance/bill.pdf", "category": "finance", "verdict": "move", "why": "", "in_csv": true, "edited": true, "planned": {"status": "review", "dst": "Documents/Work/bill.pdf", "category": "work"}, "confidence": 0.6, "decided_by": "systemone:english", "reason": "Model: work at 0.60", "alternatives": "finance 0.3"},
  {"row": 6, "src": "odd.txt", "action": "move", "size": 5, "status": "maybe", "dst": "Documents/Work/odd.txt", "category": "work", "verdict": "refused", "why": "status 'maybe' isn't auto/review/skip", "in_csv": true, "edited": true, "planned": {"status": "review", "dst": "Documents/Work/odd.txt", "category": "work"}, "confidence": 0.55, "decided_by": "systemone:english", "reason": "Model: work at 0.55", "alternatives": ""}
 ]}
"""#

@MainActor
private func loaded() throws -> PlanReview {
    let review = PlanReview(cli: DeweyCLI(executable: URL(fileURLWithPath: "/nonexistent")), root: "/x")
    review.show(try DeweyEvent.decoder().decode(PlanRows.self, from: Data(rowsJSON.utf8)))
    return review
}

@MainActor
struct PlanReviewTests {
    @Test func countsEveryFilter() throws {
        let r = try loaded()
        #expect(r.visible.count == 6)
        #expect(r.counts[.all] == 6)
        #expect(r.counts[.auto] == 2)
        #expect(r.counts[.review] == 2)
        #expect(r.counts[.skip] == 1)
        #expect(r.counts[.folder] == 1)
        #expect(r.counts[.changed] == 2)   // edited in Numbers
        #expect(r.counts[.problems] == 1)
        r.filter = .review
        #expect(r.visible.map(\.id) == [2, 4])
    }

    @Test func searchLooksAtPathsCategoriesAndReasons() throws {
        let r = try loaded()
        r.search = "finance"
        #expect(Set(r.visible.map(\.id)) == [5])
        r.search = "DOCUMENTS/work"
        #expect(Set(r.visible.map(\.id)) == [2, 6])
        r.search = "installer"
        #expect(r.visible.map(\.id) == [1])
    }

    @Test func sortsByStatusThenAnyColumn() throws {
        let r = try loaded()
        r.sortOrder = [KeyPathComparator(\PlanReview.Row.statusRank), KeyPathComparator(\PlanReview.Row.src)]
        #expect(r.visible.map(\.id) == [5, 1, 2, 4, 3, 6])  // auto, review, skip, then "maybe"
        r.sortOrder = [KeyPathComparator(\PlanReview.Row.size, order: .reverse)]
        #expect(r.visible.first?.id == 4)
    }

    @Test func approvingReviewRowsMakesThemAutoUntilSaved() throws {
        let r = try loaded()
        r.setStatus("auto", for: [2, 4])
        #expect(r.pending.count == 2)
        #expect(r.counts[.auto] == 4)
        #expect(r.counts[.review] == 0)
        let row = try #require(r.displayRow(2))
        #expect(row.status == "auto")
        #expect(row.pending)
        #expect(row.changed)
        let json = String(decoding: r.editsJSON(), as: UTF8.self)
        #expect(json == #"[{"row":2,"status":"auto"},{"row":4,"status":"auto"}]"#)
    }

    @Test func settingWhatTheCSVAlreadySaysIsNoChange() throws {
        let r = try loaded()
        r.setStatus("auto", for: [1])
        r.setCategory("rule:installer", for: [1])
        r.setDestination("  Installers/setup.dmg ", for: 1)
        #expect(!r.hasChanges)
        r.setStatus("skip", for: [2])
        r.setStatus("review", for: [2])  // and back
        #expect(!r.hasChanges)
    }

    @Test func aNewCategoryPreviewsWhereApplyWillPutIt() throws {
        let r = try loaded()
        r.setCategory("finance", for: [1])
        let moved = try #require(r.displayRow(1))
        #expect(moved.dst == "Documents/Finance/setup.dmg")
        #expect(moved.dstIsPreview)
        r.setCategory("other", for: [2])  // a leave-it-here category
        #expect(r.displayRow(2)?.dst == "minutes.docx")
        r.setCategory("mixed", for: [4])  // a folder kind that stays
        #expect(r.displayRow(4)?.dst == "Taxes")
        #expect(String(decoding: r.editsJSON(), as: UTF8.self)
                == #"[{"category":"finance","row":1},{"category":"other","row":2},{"category":"mixed","row":4}]"#)
    }

    @Test func aDestinationEndingInSlashMeansIntoThatFolder() throws {
        let r = try loaded()
        r.setDestination("Archive/2024/", for: 3)
        #expect(r.displayRow(3)?.dst == "Archive/2024/a.py")
        #expect(r.pending[3]?.dst == "Archive/2024/")  // dewey does the joining on save
        r.setDestination("   ", for: 3)  // empty is ignored
        #expect(r.pending[3]?.dst == "Archive/2024/")
    }

    @Test func revertToPlanUndoesANumbersEdit() throws {
        let r = try loaded()
        r.revertToPlan([5])
        #expect(r.pending[5] == PlanReview.Edit(status: "review", category: "work", dst: "Documents/Work/bill.pdf"))
        let row = try #require(r.displayRow(5))
        #expect(row.status == "review")
        #expect(row.dst == "Documents/Work/bill.pdf")
        #expect(!row.changed)
        r.undoChanges([5])
        #expect(!r.hasChanges)
        #expect(r.displayRow(5)?.changed == true)
    }

    @Test func categoryChoicesPutFolderKindsFirstForFoldersAndKeepTheCurrentValue() throws {
        let r = try loaded()
        #expect(r.categoryChoices(for: 1) == ["rule:installer", "finance", "work", "code", "other"])
        #expect(r.categoryChoices(for: 4) == ["documents", "mixed", "finance", "work", "code", "other"])
        #expect(r.home(of: "documents", folder: true) == "Documents")
        #expect(r.home(of: "documents", folder: false) == nil)
        #expect(r.home(of: "other", folder: false) == "")
    }

    @Test func anotherPlanDropsChangesTheSamePlanKeepsThem() throws {
        let r = try loaded()
        r.setStatus("auto", for: [2])
        var same = try DeweyEvent.decoder().decode(PlanRows.self, from: Data(rowsJSON.utf8))
        same.csvSha256 = "changed-in-numbers"
        r.show(same)
        #expect(r.pending[2]?.status == "auto")
        same.planId = 4
        r.show(same)
        #expect(!r.hasChanges)
    }
}

/// PlanReview against the real dewey: the plan's verification step ("approve review rows in the
/// app, then see them as auto in plan-N.csv"), and a save that loses to Numbers.
@MainActor @Suite(.enabled(if: realDewey != nil, "needs ~/.venvs/dewey (see README)"), .timeLimit(.minutes(1)))
struct PlanReviewWithDeweyTests {
    /// Two files a rule claims (auto) and three folders kept whole (review), planned rules-only.
    func plannedFolder() async throws -> (PlanReview, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "dewey-review-\(UUID().uuidString)")
        let fm = FileManager.default
        for (path, text) in [("setup.dmg", "dmg"), ("Screenshot 2025-03-04 at 10.11.12.png", "png"),
                             ("Folder A/notes.txt", "notes"), ("Folder B/letter.txt", "letter"),
                             ("Folder C/report.txt", "report")] {
            let url = root.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let cli = DeweyCLI(executable: realDewey!)
        struct Any_: Decodable, Sendable {}
        _ = try await cli.run(["run", root.path, "--backend", "none"], as: Any_.self)
        let review = PlanReview(cli: cli, root: root.path)
        await review.load()
        return (review, root)
    }

    private func csvStatuses(_ review: PlanReview) throws -> [String: String] {
        let text = try String(contentsOfFile: review.plan!.csv, encoding: .utf8)
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline).dropFirst() {  // "\r\n" is one Character
            let cols = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            out[cols[3]] = cols[1]  // row,status,action,src,…
        }
        return out
    }

    @Test func approvedReviewRowsAreAutoInTheCSV() async throws {
        let (review, root) = try await plannedFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let folders = review.visible.filter { $0.status == "review" }.map(\.id)
        #expect(folders.count == 3)
        review.setStatus("auto", for: folders)
        #expect(await review.save())
        #expect(!review.hasChanges)
        #expect(review.notice?.hasPrefix("Saved 3 changes") == true)
        let statuses = try csvStatuses(review)
        #expect(statuses["Folder A"] == "auto")
        #expect(statuses["Folder B"] == "auto")
        #expect(statuses["Folder C"] == "auto")
        #expect(statuses["setup.dmg"] == "auto")
        // what dewey reads back: approved, and marked as changed from the plan
        #expect(review.counts[.review] == 0)
        #expect(review.counts[.changed] == 3)
    }

    @Test func theCategoryPreviewMatchesWhatDeweyResolves() async throws {
        let (review, root) = try await plannedFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let dmg = try #require(review.visible.first { $0.src == "setup.dmg" }?.id)
        review.setCategory("finance", for: [dmg])
        let preview = review.displayRow(dmg)?.dst
        let folderA = try #require(review.visible.first { $0.src == "Folder A" }?.id)
        review.setDestination("Archive/", for: folderA)
        #expect(await review.save())
        #expect(review.displayRow(dmg)?.dst == preview)
        #expect(review.displayRow(dmg)?.dst == "Documents/Finance/setup.dmg")
        #expect(review.displayRow(folderA)?.dst == "Archive/Folder A")
        #expect(review.displayRow(dmg)?.verdict == "move")
    }

    @Test func aSaveFromNumbersInBetweenIsNotOverwritten() async throws {
        let (review, root) = try await plannedFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let csv = review.plan!.csv
        let id = try #require(review.visible.first { $0.src == "Folder A" }?.id)
        review.setStatus("auto", for: [id])
        // "Numbers" rejects Folder B in the meantime
        var text = try String(contentsOfFile: csv, encoding: .utf8)
        text = text.replacingOccurrences(of: ",review,folder,Folder B,", with: ",skip,folder,Folder B,")
        try text.write(toFile: csv, atomically: true, encoding: .utf8)

        #expect(await review.save() == false)
        #expect(review.notice?.contains("changed outside Dewey") == true)
        #expect(review.pending[id]?.status == "auto")       // kept, to save again
        #expect(try csvStatuses(review)["Folder A"] == "review")  // nothing written
        #expect(await review.save())
        let statuses = try csvStatuses(review)
        #expect(statuses["Folder A"] == "auto")
        #expect(statuses["Folder B"] == "skip")              // Numbers' edit survived
    }
}

extension PlanReviewWithDeweyTests {
    @Test func reloadSaysWhenTheCSVChangedOutsideDewey() async throws {
        let (review, root) = try await plannedFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        await review.reload()
        #expect(review.notice == nil)  // nothing changed
        let csv = review.plan!.csv
        let text = try String(contentsOfFile: csv, encoding: .utf8)
        try text.replacingOccurrences(of: ",review,folder,Folder B,", with: ",skip,folder,Folder B,")
            .write(toFile: csv, atomically: true, encoding: .utf8)
        await review.reload()
        #expect(review.notice?.contains("saved outside Dewey") == true)
        #expect(review.visible.first { $0.src == "Folder B" }?.status == "skip")
    }
}
