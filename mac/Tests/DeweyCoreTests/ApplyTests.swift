import Foundation
import Testing
@testable import DeweyCore

// MARK: - decoding what dewey apply / undo return

@Suite struct ApplyResultsTests {
    private func decode<T: Decodable>(_ json: String, as: T.Type) throws -> T {
        try DeweyEvent.decoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func aDryRunListsEveryRowAndEveryRefusal() throws {
        let p = try decode(#"""
        {"plan_id": 1, "dry_run": true, "bytes": 10,
         "refused": [{"row": 4, "src": "odd.txt", "why": "category 'nope' isn't a folder key"}],
         "selected": [{"row": 1, "src": "setup.dmg", "dst": "Installers/setup.dmg", "status": "auto",
                       "category": "rule:installer", "action": "move", "reason": "Installer", "size": 4},
                      {"row": 3, "src": "Folder A", "dst": "Documents/Folder A", "status": "review",
                       "category": "documents", "action": "folder", "reason": null, "size": 6}]}
        """#, as: ApplyPreview.self)
        #expect(p.planId == 1)
        #expect(p.files == 1)
        #expect(p.folders == 1)
        #expect(p.count(status: "review") == 1)
        #expect(p.selected[1].reason == nil)
        #expect(p.selected[1].name == "Folder A")
        #expect(p.refused.first?.why.hasPrefix("category") == true)
        #expect(p.leavesFolderFor == nil)  // a dewey before 0.2.1 doesn't say where things go

        let out = try decode(#"""
        {"plan_id": 1, "dry_run": true, "bytes": 0, "refused": [], "selected": [],
         "dest_root": "/Volumes/Big/Sorted", "dest_outside": true}
        """#, as: ApplyPreview.self)
        #expect(out.leavesFolderFor == "/Volumes/Big/Sorted")
    }

    @Test func aMoveAndANothingToDoDecodeAlike() throws {
        let moved = try decode(#"""
        {"batch": "20261118-041259-p1", "plan_id": 1, "root": "/r", "dest_root": "/r",
         "counts": {"moved": 1, "skipped": 1, "failed": 1, "bytes_moved": 4, "pruned_dirs": 0},
         "moved": [{"from": "/r/a.dmg", "to": "/r/Installers/a.dmg", "reason": "x", "category": "rule:installer",
                    "decided_by": "rule:installer", "confidence": 1.0, "status": "auto", "hash": null, "size": 4,
                    "method": "rename", "at": "2026-11-18T04:12:59-05:00"}],
         "skipped": [{"row": 2, "src": "b.png", "why": "source no longer exists"}],
         "failed": [{"row": 3, "src": "c.zip", "error": "PermissionError: denied"}],
         "pruned_dirs": [], "undo": "dewey undo", "dry_run": false, "refused": []}
        """#, as: ApplyResult.self)
        #expect(moved.batch == "20261118-041259-p1")
        #expect(moved.counts.bytesMoved == 4)
        #expect(moved.moved.first?.to == "/r/Installers/a.dmg")
        #expect(moved.skipped.first?.text == "source no longer exists")
        #expect(moved.failed.first?.text == "PermissionError: denied")
        #expect(moved.movedText == "1 file")  // no "kind": an older dewey, counted as files

        let nothing = try decode(#"""
        {"plan_id": 2, "dry_run": false, "batch": null, "moved": [], "skipped": [], "failed": [], "refused": [],
         "counts": {"moved": 0, "skipped": 0, "failed": 0, "bytes_moved": 0, "pruned_dirs": 0}}
        """#, as: ApplyResult.self)
        #expect(nothing.batch == nil)
        #expect(nothing.prunedDirs.isEmpty)
        #expect(nothing.destRoot == nil)
    }

    @Test func aPlanWhoseRowsHaveMovedHasNothingLeftToMove() throws {
        let applied = try decode(#"""
        {"plan_id": 1, "dry_run": true, "bytes": 0, "refused": [], "selected": [], "already_moved": 120}
        """#, as: ApplyPreview.self)
        #expect(applied.alreadyMoved == 120)
        #expect(applied.hasMoved)

        let partly = try decode(#"""
        {"plan_id": 1, "dry_run": true, "bytes": 4, "refused": [], "already_moved": 3,
         "selected": [{"row": 4, "src": "late.dmg", "dst": "Installers/late.dmg", "status": "auto",
                       "category": "rule:installer", "action": "move", "reason": "Installer", "size": 4}]}
        """#, as: ApplyPreview.self)
        #expect(!partly.hasMoved)  // one row was approved since: it can still move

        let nothingMarked = try decode(#"""
        {"plan_id": 1, "dry_run": true, "bytes": 0, "refused": [], "selected": [], "already_moved": 0}
        """#, as: ApplyPreview.self)
        #expect(!nothingMarked.hasMoved)  // "Nothing to move": no row is marked Move
        let older = try decode(#"""
        {"plan_id": 1, "dry_run": true, "bytes": 0, "refused": [], "selected": []}
        """#, as: ApplyPreview.self)
        #expect(older.alreadyMoved == nil)  // a dewey before 0.2.2 doesn't say
        #expect(!older.hasMoved)
    }

    @Test func undoIsOfferedOnlyWhenSomethingMoved() throws {
        // dewey 0.2.1 named a batch for a move in which every row was skipped
        let nothing = try decode(#"""
        {"batch": "20261118-041259-p1-002", "plan_id": 1, "dry_run": false, "moved": [], "failed": [], "refused": [],
         "counts": {"moved": 0, "skipped": 1, "failed": 0, "bytes_moved": 0, "pruned_dirs": 0},
         "skipped": [{"row": 1, "src": "a.dmg", "why": "source no longer exists"}]}
        """#, as: ApplyResult.self)
        #expect(nothing.batch != nil)
        #expect(nothing.undoBatch == nil)

        let moved = try decode(#"""
        {"batch": "20261118-041259-p1", "plan_id": 1, "dry_run": false, "moved": [], "skipped": [], "failed": [],
         "refused": [], "counts": {"moved": 1, "skipped": 0, "failed": 0, "bytes_moved": 4, "pruned_dirs": 0}}
        """#, as: ApplyResult.self)
        #expect(moved.undoBatch == "20261118-041259-p1")
    }

    @Test func filesAndFoldersAreCountedApart() {
        #expect(ProgressText.items(files: 1, folders: 0) == "1 file")
        #expect(ProgressText.items(files: 4, folders: 2) == "4 files and 2 folders")
        #expect(ProgressText.items(files: 0, folders: 1) == "1 folder")
        #expect(ProgressText.items(files: 1_200, folders: 0) == "\(1_200.formatted()) files")
    }

    @Test func undoSaysWhatStayed() throws {
        let u = try decode(#"""
        {"batch": "b1", "restored": 2, "skipped": 1, "dirs_removed": 3,
         "skipped_items": [{"path": "/r/Docs/a.txt", "why": "file was modified after the move; left where it is"}]}
        """#, as: UndoResult.self)
        #expect(u.restored == 2)
        #expect(u.dirsRemoved == 3)
        #expect(u.skippedItems.first?.path == "/r/Docs/a.txt")
    }
}

// MARK: - CommandRun against a stand-in dewey

/// A stand-in `dewey apply`: FAKE_SLOW=move moves until it gets SIGINT, then names its batch like
/// the real one; FAKE_FAIL=1 fails with an error event.
private let fakeDewey = #"""
#!/bin/sh
if [ -n "$FAKE_FAIL" ]; then
  echo '{"event": "error", "code": "no_plan", "message": "no plan found; run `dewey plan` first"}'
  exit 1
fi
echo '{"event": "log", "text": "Plan 1: 2 files to move (8 B); 0 refused"}'
echo '{"event": "progress", "phase": "move", "label": "Moving", "unit": "files", "n": 1, "total": 2, "bytes": 4, "total_bytes": 8, "rate": 1, "elapsed": 0.1, "eta": 0.1, "extra": "", "done": false}'
if [ "$FAKE_SLOW" = "move" ]; then
  trap 'echo "{\"event\": \"interrupted\", \"batch\": \"20261118-050000-p1\", \"message\": \"stopped\"}"; exit 130' INT
  while :; do sleep 0.05; done
fi
echo '{"event": "progress", "phase": "move", "label": "Moving", "unit": "files", "n": 2, "total": 2, "bytes": 8, "total_bytes": 8, "rate": 2, "elapsed": 0.2, "eta": 0, "extra": "", "done": true}'
echo '{"event": "result", "data": {"batch": "20261118-050000-p1", "plan_id": 1, "counts": {"moved": 2, "skipped": 0, "failed": 0, "bytes_moved": 8, "pruned_dirs": 0}, "moved": [], "skipped": [], "failed": [], "pruned_dirs": [], "refused": []}}'
"""#

private func fakeCLI(_ env: [String: String] = [:]) throws -> DeweyCLI {
    let dir = FileManager.default.temporaryDirectory.appending(path: "dewey-fake-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appending(path: "dewey")
    try fakeDewey.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return DeweyCLI(executable: url, environment: ProcessInfo.processInfo.environment.merging(env) { $1 })
}

@MainActor @Suite(.timeLimit(.minutes(1)))
struct CommandRunTests {
    @Test func aMoveFinishesWithItsResultAndProgress() async throws {
        let run = CommandRun<ApplyResult>(cli: try fakeCLI(), arguments: ["apply", "/r"], phases: ["move"])
        var ends = 0
        run.onEnd = { _ in ends += 1 }
        run.start()
        #expect(run.isActive)
        await run.wait()
        #expect(run.value?.counts.moved == 2)
        #expect(ends == 1)
        #expect(run.endedAt != nil)
        guard case .done = run.progress.phase("move")?.state else {
            Issue.record("move should be done: \(String(describing: run.progress.phase("move")))")
            return
        }
        #expect(run.progress.log == ["Plan 1: 2 files to move (8 B); 0 refused"])
    }

    @Test func cancelStopsAMoveAndKeepsItsBatchToUndo() async throws {
        let run = CommandRun<ApplyResult>(cli: try fakeCLI(["FAKE_SLOW": "move"]), arguments: ["apply", "/r"],
                                          phases: ["move"])
        run.start()
        while run.progress.phase("move")?.fraction ?? 0 == 0 { try await Task.sleep(for: .milliseconds(20)) }
        let t0 = Date()
        run.cancel()
        await run.wait()
        #expect(Date().timeIntervalSince(t0) < 2)
        guard case .stopped(let batch) = run.state else {
            Issue.record("expected stopped, got \(run.state)")
            return
        }
        #expect(batch == "20261118-050000-p1")
        guard case .stopped = run.progress.phase("move")?.state else {
            Issue.record("the bar should show where it stopped")
            return
        }
    }

    @Test func anErrorEventFailsTheRun() async throws {
        let run = CommandRun<ApplyResult>(cli: try fakeCLI(["FAKE_FAIL": "1"]), arguments: ["apply", "/r"],
                                          phases: ["move"])
        run.start()
        await run.wait()
        guard case .failed(.failed(code: "no_plan", message: _)) = run.state else {
            Issue.record("expected the no_plan error, got \(run.state)")
            return
        }
        #expect(run.value == nil)
    }
}

// MARK: - the real dewey: preview, move, undo

/// The plan's Phase 5 check: files move into place, and Undo puts them all back.
@MainActor @Suite(.enabled(if: realDewey != nil, "needs ~/.venvs/dewey (see README)"), .timeLimit(.minutes(1)))
struct ApplyWithDeweyTests {
    static let files = [("setup.dmg", "dmg"), ("Screenshot 2025-03-04 at 10.11.12.png", "png"),
                        ("Folder A/notes.txt", "notes"), ("Folder B/letter.txt", "letter")]

    /// Two files a rule claims (auto) and two folders kept whole (review), planned rules-only.
    func plannedFolder() async throws -> (DeweyCLI, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "dewey-apply-\(UUID().uuidString)")
        for (path, text) in Self.files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let cli = DeweyCLI(executable: realDewey!)
        struct Any_: Decodable, Sendable {}
        _ = try await cli.run(["run", root.path, "--backend", "none"], as: Any_.self)
        return (cli, root)
    }

    private func exists(_ root: URL, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: path).path)
    }

    @Test func movedFilesGoWhereThePreviewSaidAndUndoPutsThemAllBack() async throws {
        let (cli, root) = try await plannedFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let apply = ApplyPlan(cli: cli, root: root.path)
        await apply.refresh()
        let preview = try #require(apply.preview)
        #expect(preview.selected.map(\.src).sorted() == ["Screenshot 2025-03-04 at 10.11.12.png", "setup.dmg"])
        #expect(apply.canMove)

        // the review rows join the preview, and the move pins the plan the preview showed
        apply.includeReview = true
        #expect(apply.isStale && !apply.canMove)
        await apply.refresh()
        let all = try #require(apply.preview)
        #expect(all.files == 2 && all.folders == 2)
        apply.pruneEmpty = true
        let sha = try #require(all.selectionSha256)
        #expect(sha != preview.selectionSha256)  // other rows, another fingerprint
        #expect(apply.moveArguments() == ["apply", root.path, "--plan", String(all.planId), "--include-review",
                                          "--prune-empty", "--expect-sha", sha])

        let move = CommandRun<ApplyResult>(cli: cli, arguments: try #require(apply.moveArguments()), phases: ["move"])
        move.start()
        await move.wait()
        let result = try #require(move.value)
        #expect(result.counts.moved == 4)
        #expect(result.movedText == "2 files and 2 folders")
        // the result's paths are real paths (/private/var/…, where root is /var/…)
        let dest = try #require(result.destRoot)
        let moved = Set(result.moved.map { String($0.to.dropFirst(dest.count + 1)) })
        #expect(moved == Set(all.selected.map(\.dst)))
        for item in all.selected {
            #expect(exists(root, item.dst), "\(item.dst) should exist")
            #expect(!exists(root, item.src), "\(item.src) should be gone")
        }

        // History: the batch is there, with everything still out
        let status = try await cli.run(["status", root.path], as: FolderStatus.self)
        let batch = try #require(status.batches.first)
        #expect(batch.batch == result.batch)
        #expect(batch.out == 4)
        #expect(batch.movesText == "2 files and 2 folders")

        let undo = CommandRun<UndoResult>(cli: cli, arguments: ["undo", root.path, "--batch", batch.batch],
                                          phases: ["undo"])
        undo.start()
        await undo.wait()
        #expect(undo.value?.restored == 4)
        for (path, _) in Self.files { #expect(exists(root, path), "\(path) should be back") }
        for item in all.selected { #expect(!exists(root, item.dst)) }
        let after = try await cli.run(["status", root.path], as: FolderStatus.self)
        #expect(after.batches.first?.out == 0)
        #expect(after.undoable == nil)
    }

    @Test func aPlanThatFilesOutsideTheFolderSaysSoAndItsFilesComeBack() async throws {
        let (cli, root) = try await plannedFolder()
        let dest = FileManager.default.temporaryDirectory.appending(path: "dewey-sorted-\(UUID().uuidString)")
        defer { for url in [root, dest] { try? FileManager.default.removeItem(at: url) } }
        _ = try await cli.run(["plan", root.path, "--backend", "none", "--dest", dest.path], as: PlanResult.self)

        let apply = ApplyPlan(cli: cli, root: root.path)
        await apply.refresh()
        let preview = try #require(apply.preview)
        #expect(preview.leavesFolderFor?.hasSuffix(dest.lastPathComponent) == true)

        let move = CommandRun<ApplyResult>(cli: cli, arguments: try #require(apply.moveArguments()), phases: ["move"])
        move.start()
        await move.wait()
        #expect(move.value?.counts.moved == 2)
        #expect(FileManager.default.fileExists(atPath: dest.appending(path: "Installers/setup.dmg").path))

        // History knows the batch went outside, so the undo dialog can say where things come back from
        let status = try await cli.run(["status", root.path], as: FolderStatus.self)
        let batch = try #require(status.batches.first)
        #expect(batch.destOutside?.hasSuffix(dest.lastPathComponent) == true)
        let undo = CommandRun<UndoResult>(cli: cli, arguments: ["undo", root.path, "--batch", batch.batch],
                                          phases: ["undo"])
        undo.start()
        await undo.wait()
        #expect(undo.value?.restored == 2)
        #expect(exists(root, "setup.dmg"))
    }

    /// The preview is on screen; the plan is then saved again (Review in another window, Numbers).
    /// Move must not run the new plan under the old preview.
    @Test func aPlanChangedAfterThePreviewMovesNothingUntilItIsLookedAtAgain() async throws {
        let (cli, root) = try await plannedFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let apply = ApplyPlan(cli: cli, root: root.path)
        await apply.refresh()
        let shown = try #require(apply.moveArguments())

        let review = PlanReview(cli: cli, root: root.path)
        await review.load()
        let dmg = try #require(review.visible.first { $0.src == "setup.dmg" }?.id)
        review.setDestination("Somewhere Else/", for: dmg)
        #expect(await review.save())

        let stale = CommandRun<ApplyResult>(cli: cli, arguments: shown, phases: ["move"])
        stale.start()
        await stale.wait()
        #expect(stale.planChanged)
        for (path, _) in Self.files { #expect(exists(root, path), "\(path) should not have moved") }
        let status = try await cli.run(["status", root.path], as: FolderStatus.self)
        #expect(status.batches.isEmpty)

        await apply.refresh()  // what the folder does when a move ends
        #expect(apply.preview?.selected.first { $0.src == "setup.dmg" }?.dst == "Somewhere Else/setup.dmg")
        let move = CommandRun<ApplyResult>(cli: cli, arguments: try #require(apply.moveArguments()), phases: ["move"])
        move.start()
        await move.wait()
        #expect(!move.planChanged && move.value?.counts.moved == 2)
        #expect(exists(root, "Somewhere Else/setup.dmg"))
    }

    @Test func aRefusedRowIsListedAndDoesntMove() async throws {
        let (cli, root) = try await plannedFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let review = PlanReview(cli: cli, root: root.path)
        await review.load()
        let dmg = try #require(review.visible.first { $0.src == "setup.dmg" }?.id)
        review.setCategory("no-such-folder", for: [dmg])
        #expect(await review.save())

        let apply = ApplyPlan(cli: cli, root: root.path)
        await apply.refresh()
        let preview = try #require(apply.preview)
        #expect(preview.refused.map(\.src) == ["setup.dmg"])
        #expect(preview.selected.map(\.src) == ["Screenshot 2025-03-04 at 10.11.12.png"])
    }

    @Test func noPlanIsAnErrorWithACode() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "dewey-apply-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let apply = ApplyPlan(cli: DeweyCLI(executable: realDewey!), root: root.path)
        await apply.refresh()
        #expect(apply.preview == nil)
        guard case .failed(let code, _) = apply.error else {
            Issue.record("expected an error event, got \(String(describing: apply.error))")
            return
        }
        #expect(code == "no_plan" || code == "no_catalog")
        #expect(!apply.canMove)
    }
}
