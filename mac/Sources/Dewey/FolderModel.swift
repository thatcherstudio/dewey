import AppKit
import DeweyCore
import Observation

/// One folder in the sidebar: what `dewey status` says about it, its Scan & Plan run, and the
/// review of its latest plan.
@MainActor @Observable
final class FolderModel {
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case review = "Review"
        var id: String { rawValue }
    }

    let path: String
    var tab: Tab = .overview
    var status: FolderStatus?
    var statusError: String?
    var loading = false
    /// The current or last Scan & Plan. Kept until "Done", so you can look away and come back.
    var session: ScanPlanSession?
    /// Made the first time the Review tab opens; kept so unsaved changes survive switching tabs.
    var review: PlanReview?
    @ObservationIgnored private weak var app: AppModel?

    init(path: String, app: AppModel) {
        self.path = path
        self.app = app
    }

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent.isEmpty ? path : url.lastPathComponent }
    var displayPath: String { (path as NSString).abbreviatingWithTildeInPath }
    var parentPath: String { ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath }
    var isRunning: Bool { session?.isActive ?? false }
    var hasUnsavedChanges: Bool { review?.hasChanges ?? false }

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
        } catch {
            statusError = error.localizedDescription
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
