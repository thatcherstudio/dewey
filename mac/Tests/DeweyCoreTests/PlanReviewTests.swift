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

extension PlanReviewTests {
    /// The plan above after a move: row 1 was moved by a batch (and renamed on the way, a file had
    /// taken its name), into a destination that isn't the folder itself.
    private func afterAMove() throws -> PlanReview {
        var rows = try DeweyEvent.decoder().decode(PlanRows.self, from: Data(rowsJSON.utf8))
        rows.destRoot = "/x/Sorted"
        rows.rows[0].verdict = "moved"
        rows.rows[0].dst = "Installers/setup (2).dmg"
        rows.rows[0].why = "moved by batch 20261121-090000-p3; undo that batch to move it again"
        let review = PlanReview(cli: DeweyCLI(executable: URL(fileURLWithPath: "/nonexistent")), root: "/x")
        review.show(rows)
        return review
    }

    @Test func aRowThatMovedIsCountedAsMovedNotAsWaitingToMove() throws {
        let r = try afterAMove()
        #expect(r.counts[.moved] == 1)
        #expect(r.counts[.auto] == 1)  // row 5; row 1 is auto in the CSV too, and done
        #expect(r.counts[.all] == 6)
        r.filter = .moved
        #expect(r.visible.map(\.id) == [1])
        #expect(r.visible.first?.isMoved == true)
        r.filter = .auto
        #expect(r.visible.map(\.id) == [5])
    }

    @Test func aRowThatMovedCantBeChanged() throws {
        let r = try afterAMove()
        r.setStatus("skip", for: [1, 2])
        r.setCategory("finance", for: [1])
        r.setDestination("Elsewhere/", for: 1)
        r.revertToPlan([1])
        #expect(Array(r.pending.keys) == [2])
    }

    @Test func aRowThatMovedIsShownWhereItIsNow() throws {
        let r = try afterAMove()
        #expect(r.sourceURL(1)?.path == "/x/Sorted/Installers/setup (2).dmg")
        #expect(r.sourceURL(2)?.path == "/x/minutes.docx")  // still where the plan found it
    }

    @Test func unsavedChangesToARowThatMovedMeanwhileAreDropped() throws {
        let r = try loaded()
        r.setStatus("skip", for: [1, 2])
        var rows = try DeweyEvent.decoder().decode(PlanRows.self, from: Data(rowsJSON.utf8))
        rows.rows[0].verdict = "moved"  // the same plan, read again after a move
        r.show(rows)
        #expect(Array(r.pending.keys) == [2])
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

/// After a save and after a move, the app and dewey agree about what is done (0.2.2, group B).
extension PlanReviewWithDeweyTests {
    @Test func aSaveIsToldToTheFolderAndStatusCountsTheCSVAsItIsNow() async throws {
        let (review, root) = try await plannedFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        var saves = 0
        review.onSaved = { saves += 1 }
        let before = try await review.cli.run(["status", root.path], as: FolderStatus.self)
        #expect(before.latestPlan?.summary.folder.n == 3)
        review.setStatus("auto", for: review.visible.filter { $0.status == "review" }.map(\.id))
        #expect(await review.save())
        #expect(saves == 1)
        let after = try await review.cli.run(["status", root.path], as: FolderStatus.self)
        #expect(after.latestPlan?.summary.folder.n == 0)  // 0.2.1: still 3 to review, even after a relaunch
        #expect(after.latestPlan?.summary.auto.n == 5)
        #expect(review.plan?.summary == after.latestPlan?.summary)
    }

    @Test func aSaveThatLosesToNumbersIsNotToldAsASave() async throws {
        let (review, root) = try await plannedFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        var saves = 0
        review.onSaved = { saves += 1 }
        let id = try #require(review.visible.first { $0.src == "Folder A" }?.id)
        review.setStatus("auto", for: [id])
        let csv = review.plan!.csv
        let text = try String(contentsOfFile: csv, encoding: .utf8)
        try text.replacingOccurrences(of: ",review,folder,Folder B,", with: ",skip,folder,Folder B,")
            .write(toFile: csv, atomically: true, encoding: .utf8)
        #expect(await review.save() == false)
        #expect(saves == 0)
    }

    @Test func anAppliedPlanHasNothingLeftToMoveAndItsRowsSayMoved() async throws {
        let (review, root) = try await plannedFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = review.cli
        let apply = ApplyPlan(cli: cli, root: root.path)
        await apply.refresh()
        #expect(apply.canMove)
        #expect(!apply.hasMoved)
        let moved = try await cli.run(try #require(apply.moveArguments()), as: ApplyResult.self)
        #expect(moved.counts.moved == 2)
        #expect(moved.undoBatch == moved.batch)

        await apply.refresh()  // 0.2.1: the same two rows again, and Move enabled
        #expect(apply.preview?.selected.isEmpty == true)
        #expect(apply.preview?.alreadyMoved == 2)
        #expect(apply.hasMoved)
        #expect(!apply.canMove)
        #expect(apply.moveArguments() == nil)

        await review.load()
        #expect(review.counts[.moved] == 2)
        #expect(review.counts[.auto] == 0)
        let dmg = try #require(review.visible.first { $0.src == "setup.dmg" })
        #expect(dmg.isMoved)
        let now = try #require(review.sourceURL(dmg.id))
        #expect(FileManager.default.fileExists(atPath: now.path))  // Show in Finder has a file to show
        #expect(now.path.hasSuffix("/Installers/setup.dmg"))

        var status = try await cli.run(["status", root.path], as: FolderStatus.self)
        #expect(status.latestCanBeUndone)
        #expect(status.latestPlan?.summary.moved.n == 2)
        #expect(status.latestPlan?.summary.auto.n == 0)

        let undone = try await cli.run(["undo", root.path], as: UndoResult.self)
        #expect(undone.restored == 2)
        status = try await cli.run(["status", root.path], as: FolderStatus.self)
        #expect(!status.latestCanBeUndone)
        #expect(status.undoable == nil)
        await apply.refresh()
        #expect(apply.canMove)  // put back: they can move again
        #expect(!apply.hasMoved)
    }

    @Test func aMoveThatMovesNothingNamesNoBatchToUndo() async throws {
        let (review, root) = try await plannedFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.removeItem(at: root.appending(path: "setup.dmg"))
        try fm.removeItem(at: root.appending(path: "Screenshot 2025-03-04 at 10.11.12.png"))
        let result = try await review.cli.run(["apply", root.path], as: ApplyResult.self)
        #expect(result.counts.moved == 0)
        #expect(result.skipped.count == 2)
        #expect(result.batch == nil)  // 0.2.1: a batch, "Undo This Batch…", "Put back 0 files?"
        #expect(result.undoBatch == nil)
        let status = try await review.cli.run(["status", root.path], as: FolderStatus.self)
        #expect(status.undoable == nil)
        #expect(status.batches.isEmpty)
    }
}

// MARK: - changes made while a save or a reload is running (0.2.2, group C)

extension PlanReviewTests {
    private func rows() throws -> [Int: PlanRow] {
        let plan = try DeweyEvent.decoder().decode(PlanRows.self, from: Data(rowsJSON.utf8))
        return Dictionary(uniqueKeysWithValues: plan.rows.map { ($0.row, $0) })
    }

    @Test func whatWasSentAndNotTouchedSinceIsSaved() throws {
        let sent = [2: PlanReview.Edit(status: "auto"), 3: PlanReview.Edit(category: "work")]
        #expect(PlanReview.unsaved(after: sent, now: sent, rows: try rows()).isEmpty)
    }

    @Test func aChangeMadeWhileTheSaveRanIsStillUnsaved() throws {
        let sent = [2: PlanReview.Edit(status: "auto")]
        var now = sent
        now[4] = PlanReview.Edit(status: "skip")                    // another row
        now[2] = PlanReview.Edit(status: "auto", category: "finance")  // another field of the row sent
        let left = PlanReview.unsaved(after: sent, now: now, rows: try rows())
        #expect(left[4] == PlanReview.Edit(status: "skip"))
        #expect(left[2]?.category == "finance")
        #expect(left.count == 2)
    }

    @Test func aRowPutBackWhileTheSaveRanIsAChangeAgain() throws {
        // Row 2 is "review" in the CSV. Approve, Save, and before the save answers, back to review:
        // nothing is pending by then, but the CSV is about to say "auto".
        let sent = [2: PlanReview.Edit(status: "auto", category: "finance"), 3: PlanReview.Edit(dst: "Archive/")]
        let now = [2: PlanReview.Edit(category: "finance")]
        let left = PlanReview.unsaved(after: sent, now: now, rows: try rows())
        #expect(left[2] == PlanReview.Edit(status: "review", category: "finance"))
        #expect(left[3] == PlanReview.Edit(dst: "Code/a.py"))  // "Undo Unsaved Changes" on a typed destination
    }
}

/// A stand-in dewey with one plan of one row, whose status `edit` sets to "auto". A `rows` that
/// finds the file `slow` next to it reads the plan, then takes its time to answer: the reload that
/// is still on its way when Save is pressed.
private let slowRowsDewey = #"""
#!/bin/sh
dir=$(dirname "$0")
case "$1" in
  rows)
    status=$(cat "$dir/status")
    if [ -e "$dir/slow" ]; then rm "$dir/slow"; sleep 0.7; fi
    echo "{\"event\": \"result\", \"data\": {\"plan_id\": 3, \"created\": \"2026-11-17T21:00:00-05:00\", \"root\": \"/x\", \"dest_root\": \"/x\", \"csv\": \"/x/.dewey/plan-3.csv\", \"csv_sha256\": \"sha-$status\", \"summary\": {}, \"categories\": [], \"folder_kinds\": [], \"auto_confidence\": 0.85, \"review_confidence\": 0.5, \"rows\": [{\"row\": 1, \"src\": \"a.txt\", \"action\": \"move\", \"size\": 1, \"status\": \"$status\", \"dst\": \"Docs/a.txt\", \"category\": \"work\", \"verdict\": \"move\", \"why\": \"\", \"in_csv\": true, \"edited\": false, \"planned\": {\"status\": \"review\", \"dst\": \"Docs/a.txt\", \"category\": \"work\"}}]}}" ;;
  edit)
    cat > /dev/null
    [ -e "$dir/slow-edit" ] && sleep 0.4
    echo auto > "$dir/status"
    echo '{"event": "result", "data": {"plan_id": 3, "csv": "/x/.dewey/plan-3.csv", "csv_sha256": "sha-auto", "changed": 1}}' ;;
esac
"""#

@MainActor @Suite(.timeLimit(.minutes(1)))
struct PlanReviewRaceTests {
    private func standIn() throws -> (PlanReview, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "dewey-fake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "dewey")
        try slowRowsDewey.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        try "review\n".write(to: dir.appending(path: "status"), atomically: true, encoding: .utf8)
        return (PlanReview(cli: DeweyCLI(executable: url), root: "/x"), dir)
    }

    private func until(_ condition: () -> Bool) async throws {
        while !condition() { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func aSavePressedDuringAReloadShowsWhatItSaved() async throws {
        let (review, dir) = try standIn()
        defer { try? FileManager.default.removeItem(at: dir) }
        await review.load()
        #expect(review.displayRow(1)?.status == "review")

        FileManager.default.createFile(atPath: dir.appending(path: "slow").path, contents: nil)
        let reload = Task { await review.reload() }  // coming back to the app
        try await until { review.loading }
        try await until { !FileManager.default.fileExists(atPath: dir.appending(path: "slow").path) }  // it has read the plan
        review.setStatus("auto", for: [1])
        #expect(await review.save())
        await reload.value  // the older read answers last

        // 0.2.1: the save's own read was skipped, the older rows landed: "review" again, the old
        // checksum, and the next Save said the file had changed outside Dewey
        #expect(review.displayRow(1)?.status == "auto")
        #expect(review.plan?.csvSha256 == "sha-auto")
        #expect(!review.hasChanges)
        #expect(!review.loading)
        #expect(review.notice == "Saved 1 change to plan-3.csv.")
    }

    @Test func aChangeMadeWhileASaveRunsIsKept() async throws {
        let (review, dir) = try standIn()
        defer { try? FileManager.default.removeItem(at: dir) }
        await review.load()
        FileManager.default.createFile(atPath: dir.appending(path: "slow-edit").path, contents: nil)
        review.setStatus("auto", for: [1])
        let save = Task { await review.save() }
        try await until { review.saving }
        review.setStatus("skip", for: [1])  // 0.2.1: wiped when the save came back
        #expect(await save.value)
        #expect(review.plan?.rows.first?.status == "auto")  // what was sent is saved
        #expect(review.pending[1] == PlanReview.Edit(status: "skip"))
        #expect(review.displayRow(1)?.status == "skip")
    }

    @Test func aRowPutBackWhileASaveRunsIsNotLeftAsSaved() async throws {
        let (review, dir) = try standIn()
        defer { try? FileManager.default.removeItem(at: dir) }
        await review.load()
        FileManager.default.createFile(atPath: dir.appending(path: "slow-edit").path, contents: nil)
        review.setStatus("auto", for: [1])
        let save = Task { await review.save() }
        try await until { review.saving }
        review.setStatus("review", for: [1])  // back to what the CSV said when it was read
        #expect(review.pending.isEmpty)
        #expect(await save.value)
        #expect(review.pending[1] == PlanReview.Edit(status: "review"))  // the CSV says auto now
        #expect(review.displayRow(1)?.status == "review")
    }
}
