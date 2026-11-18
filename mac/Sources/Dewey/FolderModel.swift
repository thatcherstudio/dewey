import AppKit
import DeweyCore
import Observation

/// One folder in the sidebar: what `dewey status` says about it, and its Scan & Plan run.
@MainActor @Observable
final class FolderModel {
    let path: String
    var status: FolderStatus?
    var statusError: String?
    var loading = false
    /// The current or last Scan & Plan. Kept until "Done", so you can look away and come back.
    var session: ScanPlanSession?
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
        session.onEnd = { [weak self] _ in
            Task { await self?.refresh() }
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
    }

    func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func open(_ path: String?) {
        guard let path else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}
