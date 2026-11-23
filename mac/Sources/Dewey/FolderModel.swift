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

    /// Which model this folder's plans ask: the Laya this app runs, or something else its own
    /// settings name. nil until `dewey status` has answered.
    var modelSource: ModelSource? {
        guard let d = status?.decider, let app else { return nil }
        return ModelSource(backend: d.backend, url: d.url, appLaya: app.laya.baseURL)
    }
    /// Plans here wait for the app's Laya and can start it (also assumed until status has answered).
    var usesAppLaya: Bool { modelSource?.isAppLaya ?? true }

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
        let session = ScanPlanSession(cli: cli, root: path, modelLoading: { [weak self] in
            guard self?.usesAppLaya ?? true else { return false }  // another server: nothing here to wait for
            if case .starting = laya.status { return true }
            return false
        })
        session.onEnd = { [weak self] s in
            Task {
                await self?.refresh()
                guard let review = self?.review else { return }
                if case .finished = s.state {
                    await review.load()  // a new plan: the review shows it (changes to the old one were confirmed away)
                } else {
                    // no new plan, but settings saved for this run still change where its rows go
                    await review.load(planId: review.plan?.planId)
                }
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

    /// A tab that has something to say (a save that failed), in front of a run screen that has ended.
    func show(_ tab: Tab) {
        guard !isRunning else { return }
        session = nil
        moveRun = nil
        undoRun = nil
        self.tab = tab
    }

    /// What Review and Settings have unsaved, in a sentence each, for the questions that ask about them.
    var unsavedSummary: String {
        var text = ""
        if let n = review?.pending.count, n > 0 {
            text += "Review has \(ProgressText.count(n)) unsaved \(n == 1 ? "change" : "changes") to the plan."
        }
        if hasUnsavedSettings { text += (text.isEmpty ? "" : " ") + "Settings has unsaved changes." }
        return text
    }

    /// Save what Review and Settings have unsaved. False when one of them couldn't be saved: its tab
    /// is then the one showing, with the reason.
    func saveChanges() async -> Bool {
        if let review, review.hasChanges, await !review.save() {
            show(.review)
            return false
        }
        if let settings, settings.hasChanges {
            guard await settings.save() else {
                show(.settings)
                return false
            }
            settingsSaved()
        }
        return true
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

    /// After a move or undo: the catalog, the batches, the preview and which rows have moved changed.
    private func filesMoved() {
        Task {
            await refresh()
            if apply != nil { await apply?.refresh() }
            if let review { await review.load(planId: review.plan?.planId) }  // unsaved changes are kept
        }
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    /// Close a move that didn't start because the plan changed, onto Apply and its new preview.
    func dismissToApply() {
        guard !isRunning else { return }
        moveRun = nil
        undoRun = nil
        tab = .apply
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
            await refresh()  // a fixed dewey.toml, and which model the folder asks now
            if let review, !review.hasChanges { await review.load() }
            if apply != nil { await apply?.refresh() }
        }
    }

    func makeReview() {
        guard review == nil, let cli = app?.cli else { return }
        let review = PlanReview(cli: cli, root: path)
        // Overview's "Latest plan" counts come from `dewey status`: read it again after every save,
        // whichever screen saved (Review, or Apply's "Save Changes").
        review.onSaved = { [weak self] in Task { await self?.refresh() } }
        self.review = review
    }

    func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func open(_ path: String?) {
        guard let path else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}
