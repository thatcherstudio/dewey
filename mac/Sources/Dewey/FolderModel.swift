import AppKit
import DeweyCore
import Observation

/// One folder in the sidebar: what `dewey status` says about it, its Scan & Plan run, the review of
/// its latest plan, moving files (Apply) and putting them back (History), and its settings.
@MainActor @Observable
final class FolderModel {
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case review = "Review"
        case apply = "Apply"
        case history = "History"
        case settings = "Settings"
        var id: String { rawValue }
    }

    let path: String
    var tab: Tab = .overview
    var status: FolderStatus?
    var statusError: String?
    /// The error's code (see src/dewey/errors.py): "config" means dewey.toml needs fixing in Settings.
    var statusErrorCode: String?
    var loading = false
    /// The current or last Scan & Plan. Kept until "Done", so you can look away and come back.
    var session: ScanPlanSession?
    /// Made the first time the Review tab opens; kept so unsaved changes survive switching tabs.
    var review: PlanReview?
    /// The Apply tab's options and preview, made the first time it opens.
    var apply: ApplyPlan?
    /// Files moving, or moved: kept until "Done", like `session`.
    var moveRun: CommandRun<ApplyResult>?
    /// Files going back (History's Undo).
    var undoRun: CommandRun<UndoResult>?
    /// The Settings tab: this folder's dewey.toml, made the first time it opens.
    var settings: FolderSettings?
    @ObservationIgnored private weak var app: AppModel?

    init(path: String, app: AppModel) {
        self.path = path
        self.app = app
    }

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent.isEmpty ? path : url.lastPathComponent }
    var displayPath: String { (path as NSString).abbreviatingWithTildeInPath }
    var parentPath: String { ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath }
    /// dewey is working on this folder (scan, plan, move or undo): one thing at a time.
    var isRunning: Bool {
        (session?.isActive ?? false) || (moveRun?.isActive ?? false) || (undoRun?.isActive ?? false)
    }
    /// A run screen is showing (running or ended, until "Done"): the tabs wait for it.
    var showsRun: Bool { session != nil || moveRun != nil || undoRun != nil }
    /// What's running, for the quit alert.
    var activity: String {
        if undoRun?.isActive == true { return "putting files back" }
        if moveRun?.isActive == true { return "moving files" }
        return "Scan & Plan"
    }
    /// Review has changes not saved into plan-N.csv (Apply waits for them).
    var hasUnsavedChanges: Bool { review?.hasChanges ?? false }
    var hasUnsavedSettings: Bool { settings?.hasChanges ?? false }

    /// Still there (an external disk may be unplugged, a folder renamed in Finder).
    var exists: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    func refresh() async {
        // A status read while a scan writes the catalog could hit "database is locked"; the run
        // refreshes this when it ends.
        guard let cli = app?.cli, !isRunning, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            status = try await cli.run(["status", path], as: FolderStatus.self)
            statusError = nil
            statusErrorCode = nil
        } catch {
            statusError = error.localizedDescription
            if case .failed(let code, _) = error as? DeweyError { statusErrorCode = code } else { statusErrorCode = nil }
        }
    }

    func scanAndPlan() {
        guard let app, let cli = app.cli, !isRunning else { return }
        let laya = app.laya
        let session = ScanPlanSession(cli: cli, root: path, modelLoading: {
            if case .starting = laya.status { return true }
            return false
        })
        session.onEnd = { [weak self] s in
            Task {
                await self?.refresh()
                // a new plan: the review shows it (changes to the old one were confirmed away)
                if case .finished = s.state, let review = self?.review { await review.load() }
            }
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        }
        self.session = session
        session.start()
    }

    /// The plan failed because the model wasn't running: start Laya, then plan again (it waits for
    /// the model to load).
    func startModelAndRetry() async {
        guard let app, let session else { return }
        await app.startLaya()
        session.retryPlan(rulesOnly: false)
    }

    /// Back to the overview.
    func dismissRun() {
        guard !isRunning else { return }
        session = nil
        tab = .overview
    }

    /// The Review tab, after a run or from the overview.
    func openReview() {
        guard !isRunning else { return }
        session = nil
        tab = .review
    }

    func makeApply() {
        guard apply == nil, let cli = app?.cli else { return }
        apply = ApplyPlan(cli: cli, root: path)
    }

    /// Move the files the Apply preview lists. Refused while Review has unsaved changes: apply reads
    /// plan-N.csv, so it would move what the file says, not what the table shows.
    func startMove() {
        guard let cli = app?.cli, !isRunning, !hasUnsavedChanges, let args = apply?.moveArguments() else { return }
        let run = CommandRun<ApplyResult>(cli: cli, arguments: args, phases: ["move"])
        run.onEnd = { [weak self] _ in self?.filesMoved() }
        moveRun = run
        run.start()
    }

    /// Put back the files of one batch.
    func undo(batch: String) {
        guard let cli = app?.cli, !isRunning else { return }
        moveRun = nil
        let run = CommandRun<UndoResult>(cli: cli, arguments: ["undo", path, "--batch", batch], phases: ["undo"])
        run.onEnd = { [weak self] _ in self?.filesMoved() }
        undoRun = run
        run.start()
    }

    /// After a move or undo: the catalog, the batches and the preview changed.
    private func filesMoved() {
        Task {
            await refresh()
            if apply != nil { await apply?.refresh() }
        }
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    /// Close the move or undo screen, onto History (where the batch now is).
    func dismissMoves() {
        guard !isRunning else { return }
        moveRun = nil
        undoRun = nil
        tab = .history
    }

    /// The journal of a batch: the readable summary when the batch finished, else the raw log.
    func journal(_ batch: String) -> URL? {
        guard let state = status?.state else { return nil }
        let dir = URL(fileURLWithPath: state).appending(path: "moves")
        for name in ["\(batch).json", "\(batch).jsonl"] {
            let url = dir.appending(path: name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    func makeSettings() {
        guard settings == nil, let cli = app?.cli else { return }
        settings = FolderSettings(cli: cli, root: path)
    }

    /// New settings: category paths change where planned rows go, and Review's category list.
    func settingsSaved() {
        Task {
            if statusErrorCode == "config" { await refresh() }
            if let review, !review.hasChanges { await review.load() }
            if apply != nil { await apply?.refresh() }
        }
    }

    func makeReview() {
        guard review == nil, let cli = app?.cli else { return }
        review = PlanReview(cli: cli, root: path)
    }

    func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func open(_ path: String?) {
        guard let path else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}
