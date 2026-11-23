import AppKit
import DeweyCore
import Observation

enum Prefs {
    static let deweyPath = "deweyPath"
    static let layaServePath = "layaServePath"
    static let layaURL = "layaURL"
    static let startLayaOnLaunch = "startLayaOnLaunch"
    static let selection = "selection"
    /// Where Install Laya puts Laya, instead of ~/Library/Application Support/Dewey/Laya. Not in the
    /// Settings window: it is for trying the installer (`open Dewey.app --args -layaInstallRoot DIR`).
    static let layaInstallRoot = "layaInstallRoot"
    static let defaultLayaURL = "http://127.0.0.1:8000"

    static func register() {
        UserDefaults.standard.register(defaults: [startLayaOnLaunch: true, layaURL: defaultLayaURL])
    }
}

/// The tools inside the app: build-app.sh puts dewey (with its own Python) in Contents/Resources/bin.
enum Bundled {
    static let tools = Bundle.main.resourceURL?.appending(path: "bin")

    static func contains(_ url: URL) -> Bool { url.path.hasPrefix(Bundle.main.bundlePath + "/") }
}

/// The dewey checkout this app was built from: …/mac/Sources/Dewey/AppModel.swift, four levels up.
/// The setup screen uses it to show install commands with the real path in them.
enum RepoPath {
    static let url: URL? = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { u.deleteLastPathComponent() }
        return FileManager.default.fileExists(atPath: u.appending(path: "pyproject.toml").path) ? u : nil
    }()
}

@MainActor @Observable
final class AppModel {
    enum Check: Equatable {
        case checking
        case ok(String)
        case problem(String)

        var isOK: Bool { if case .ok = self { true } else { false } }
    }

    var dewey: Check = .checking
    var layaServe: Check = .checking
    /// False until dewey has been checked once (the window shows a spinner, not a flash of setup).
    var checkedOnce = false
    /// dewey passed its last finished check, so "Check Again" keeps the main window up while it runs.
    var lastDeweyOK = false
    var deweyURL: URL?
    var layaServeURL: URL?
    /// The uv Install Laya runs: the app's own, else one on this Mac (`swift run` has none inside).
    var uvURL: URL?
    /// What Install Laya's folder holds (0: nothing), for its Remove button.
    var layaInstallBytes: Int64 = 0
    var layaRemoveError: String?
    var appInfo: AppInfo?
    let laya: LayaController
    let installer: LayaInstaller

    let folders = FolderStore()
    var selection: SidebarItem? {
        didSet { UserDefaults.standard.set(selection?.storageKey, forKey: Prefs.selection) }
    }
    @ObservationIgnored private var folderModels: [String: FolderModel] = [:]

    var cli: DeweyCLI? { deweyURL.map { DeweyCLI(executable: $0) } }
    var deweyReady: Bool { dewey.isOK }
    /// The sidebar and folders, rather than the setup screen. Only dewey is required: without Laya,
    /// plans use rules and duplicates only.
    var showsMain: Bool {
        switch dewey {
        case .ok: true
        case .checking: lastDeweyOK
        case .problem: false
        }
    }
    var everythingReady: Bool {
        if case .ready = laya.status { return dewey.isOK && layaServe.isOK }
        return false
    }

    /// The laya-serve in use is the one Install Laya set up.
    var layaInstalledByDewey: Bool { layaServeURL == installer.layout.layaServe }

    var deweyFix: String { SetupCommands.installDewey(repo: RepoPath.url) }
    var layaFix: String { SetupCommands.installLaya }

    init() {
        Prefs.register()
        laya = LayaController(baseURL: Self.layaBaseURL(), record: Self.layaLayout().serverRecord)
        installer = LayaInstaller(layout: Self.layaLayout())
        selection = SidebarItem(storageKey: UserDefaults.standard.string(forKey: Prefs.selection))
            .flatMap { item in
                if case .folder(let p) = item, !folders.paths.contains(p) { return nil }
                return item
            }
            ?? folders.paths.first.map(SidebarItem.folder)
    }

    static func layaLayout() -> LayaInstaller.Layout {
        guard let root = UserDefaults.standard.string(forKey: Prefs.layaInstallRoot), !root.isEmpty else { return .standard }
        return LayaInstaller.Layout(root: URL(fileURLWithPath: (root as NSString).expandingTildeInPath))
    }

    static func layaBaseURL() -> URL {
        let s = UserDefaults.standard.string(forKey: Prefs.layaURL) ?? Prefs.defaultLayaURL
        return URL(string: s.trimmingCharacters(in: .whitespaces)) ?? URL(string: Prefs.defaultLayaURL)!
    }

    func launch() async {
        await laya.stopLeftover()  // a laya-serve the last Dewey didn't get to stop (a crash, Force Quit)
        await checkAll()
        if UserDefaults.standard.bool(forKey: Prefs.startLayaOnLaunch), deweyReady, layaServeURL != nil {
            await startLaya()
        }
    }

    func checkAll() async {
        dewey = .checking
        layaServe = .checking
        if !laya.isRunning { laya.baseURL = Self.layaBaseURL() }
        let d = UserDefaults.standard
        let deweyPref = d.string(forKey: Prefs.deweyPath) ?? ""
        let layaPref = d.string(forKey: Prefs.layaServePath) ?? ""
        let locator = ToolLocator(bundledDir: Bundled.tools, installedDir: installer.layout.bin)
        async let foundDewey = locator.locate(.dewey, preferred: deweyPref)
        async let foundLaya = locator.locate(.layaServe, preferred: layaPref)
        async let foundUV = locator.locate(.uv)
        async let installBytes = installer.diskUsage()

        deweyURL = await foundDewey
        appInfo = nil
        if let url = deweyURL {
            do {
                let info = try await DeweyCLI(executable: url).appInfo()
                appInfo = info
                if info.protocolVersion == AppInfo.supportedProtocol {
                    dewey = .ok("dewey \(info.version), Python \(info.python)\n"
                                + (Bundled.contains(url) ? "inside Dewey.app" : url.path))
                } else {
                    dewey = .problem("\(url.path) speaks app protocol \(info.protocolVersion); this app needs "
                                     + "\(AppInfo.supportedProtocol). "
                                     + (deweyPref.isEmpty ? "Reinstall dewey from the checkout this app was built from."
                                        : "Clear the dewey path in Dewey > Settings… to use the dewey inside the app."))
                }
            } catch {
                dewey = .problem("Found \(url.path), but it didn't answer `dewey app-info`. A dewey from before the "
                                 + "Mac app can't: reinstall it with the commands below.\n\(error.localizedDescription)")
            }
        } else {
            dewey = .problem(deweyPref.isEmpty
                             ? "This Dewey has no dewey inside it (build it with `make app`), and there's none in "
                               + "~/.venvs/dewey, ~/.local/bin, Homebrew, or your shell's PATH."
                             : "The dewey path in Settings (\(deweyPref)) isn't an executable file.")
        }
        // The window waits for dewey and no longer: Laya and uv, when they aren't in the usual places,
        // are looked for in the login shell, and a slow shell profile takes its whole 5 s over that.
        lastDeweyOK = dewey.isOK
        checkedOnce = true

        layaServeURL = await foundLaya
        uvURL = await foundUV
        layaInstallBytes = await installBytes
        if let url = layaServeURL {
            layaServe = .ok(layaInstalledByDewey
                            ? "Installed by Dewey, in \((installer.layout.root.path as NSString).abbreviatingWithTildeInPath)"
                            : url.path)
        } else {
            layaServe = .problem(layaPref.isEmpty
                                 ? "Laya isn't installed. Without it, plans use your rules and duplicates only."
                                 : "The laya-serve path in Settings (\(layaPref)) isn't an executable file.")
        }
        await laya.refresh()
    }

    /// Install Laya, then start it.
    func installLaya() async {
        guard let uv = uvURL, !installer.isRunning else { return }
        await installer.install(uv: uv)
        guard installer.state == .finished else { return }
        // A laya-serve path in Settings that doesn't work would hide the new install.
        let d = UserDefaults.standard
        if let pref = d.string(forKey: Prefs.layaServePath), !pref.trimmingCharacters(in: .whitespaces).isEmpty,
           !ToolLocator.isExecutable(URL(fileURLWithPath: (pref as NSString).expandingTildeInPath)) {
            d.removeObject(forKey: Prefs.layaServePath)
        }
        await checkAll()
        await startLaya()
    }

    /// Delete what Install Laya put on this Mac, stopping the laya-serve it set up first. Laya stays
    /// stopped afterwards, even when another laya-serve is on the Mac: the user asked for no Laya.
    func removeLaya() async {
        guard !installer.isRunning, !installer.isRemoving else { return }
        layaRemoveError = nil
        if laya.executable == installer.layout.layaServe { await laya.stopAndWait() }
        do {
            try await installer.remove()
        } catch {
            layaRemoveError = error.localizedDescription
        }
        await checkAll()
    }

    func startLaya() async {
        guard let url = layaServeURL else { return }
        if !laya.isRunning { laya.baseURL = Self.layaBaseURL() }
        await laya.start(executable: url)
    }

    // MARK: - folders

    /// The model behind one sidebar folder, made on first use and kept while the app runs, so a scan
    /// keeps going when you look at another folder.
    func folder(_ path: String) -> FolderModel {
        if let f = folderModels[path] { return f }
        let f = FolderModel(path: path, app: self)
        folderModels[path] = f
        return f
    }

    /// Folders with dewey running (scan, plan, move or undo).
    var busyFolders: [FolderModel] {
        folders.paths.compactMap { folderModels[$0] }.filter(\.isRunning)
    }

    func chooseFolders() {
        let panel = NSOpenPanel()
        panel.title = "Add a folder for Dewey to organize"
        panel.prompt = "Add"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    /// Adds folders (files are ignored) and selects the first one. A folder dewey won't organize (the
    /// disk, the Library, a system folder) is turned down with the reason; the home folder asks first.
    func add(_ urls: [URL]) {
        let dirs = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        var fine: [URL] = [], ask: [(URL, String)] = [], refused: [(String, String)] = []
        for url in dirs {
            let path = FolderStore.normalize(url)
            switch folders.paths.contains(path) ? .ok : RootCheck.check(path) {  // one already listed was answered before
            case .ok: fine.append(url)
            case .confirm(let why): ask.append((url, why))
            case .refuse(let why): refused.append((path, why))
            }
        }
        addChecked(fine)
        guard !ask.isEmpty || !refused.isEmpty else { return }
        Task { @MainActor in  // after the drop or the open panel has finished: an alert inside a drop stalls it
            addChecked(ask.filter { Self.confirmAdding($0.0, why: $0.1) }.map(\.0))
            if !refused.isEmpty { Self.explainRefused(refused) }
        }
    }

    private func addChecked(_ urls: [URL]) {
        var first: String?
        for url in urls.reversed() { first = folders.add(url) }  // reversed: they end up in the order chosen
        if let first { selection = .folder(first) }
    }

    private static func confirmAdding(_ url: URL, why: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Organize your whole home folder?"
        alert.informativeText = why
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Add Home Folder")
        return alert.runModal() == .alertSecondButtonReturn
    }

    private static func explainRefused(_ refused: [(path: String, why: String)]) {
        let alert = NSAlert()
        let name = { (p: String) in p == "/" ? "the whole disk" : "“\((p as NSString).lastPathComponent)”" }
        alert.messageText = refused.count == 1 ? "Dewey won't organize \(name(refused[0].path))"
            : "Dewey won't organize \(refused.count) of these folders"
        alert.informativeText = (refused.count == 1 ? [refused[0].why]
                                 : refused.map { "\(($0.path as NSString).abbreviatingWithTildeInPath): \($0.why)" })
            .joined(separator: "\n") + "\nAdd a folder of your own files instead."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Remove from Sidebar. Unsaved Review and Settings changes go with the folder's place in the
    /// sidebar, so a folder that has some asks first: save them, drop them, or keep the folder.
    func askToRemoveFolder(_ path: String) {
        guard let folder = folderModels[path], folder.hasUnsavedChanges || folder.hasUnsavedSettings else {
            return removeFolder(path)
        }
        guard !folder.isRunning else { return }
        let alert = NSAlert()
        alert.messageText = "Save your changes to “\(folder.name)” before removing it from the sidebar?"
        alert.informativeText = folder.unsavedSummary
            + " Removing the folder from the sidebar drops what isn't saved. The folder and its files stay where they are."
        alert.addButton(withTitle: "Save and Remove")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Remove Without Saving").hasDestructiveAction = true
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task {
                if await folder.saveChanges() {
                    removeFolder(path)
                } else {
                    selection = .folder(path)  // not saved, so not removed: its Review or Settings says why
                }
            }
        case .alertThirdButtonReturn:
            removeFolder(path)
        default:
            break
        }
    }

    func removeFolder(_ path: String) {
        guard !(folderModels[path]?.isRunning ?? false) else { return }
        let index = folders.paths.firstIndex(of: path)
        folders.remove(path)
        folderModels[path] = nil
        if selection == .folder(path) {
            let next = index.flatMap { folders.paths.indices.contains($0) ? folders.paths[$0] : folders.paths.last }
            selection = next.map(SidebarItem.folder)
        }
    }

    /// Folders whose plan has changes made in Review and not saved.
    var foldersWithUnsavedChanges: [FolderModel] {
        folders.paths.compactMap { folderModels[$0] }.filter(\.hasUnsavedChanges)
    }

    var foldersWithUnsavedSettings: [FolderModel] {
        folders.paths.compactMap { folderModels[$0] }.filter(\.hasUnsavedSettings)
    }

    /// App quit: SIGINT every running dewey, like Ctrl-C (it saves what's done and exits on its own).
    func cancelAllRuns() {
        for f in busyFolders {
            f.session?.cancel()
            f.moveRun?.cancel()
            f.undoRun?.cancel()
        }
    }

    /// Pick an executable with an open panel and remember it in Settings.
    func choose(_ key: String, title: String) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.showsHiddenFiles = true  // ~/.venvs and ~/.local are hidden
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: key)
        Task { await checkAll() }
    }
}

/// What the sidebar has selected.
enum SidebarItem: Hashable {
    case setup
    case folder(String)

    var storageKey: String {
        switch self {
        case .setup: "setup"
        case .folder(let p): p
        }
    }

    init?(storageKey: String?) {
        guard let k = storageKey, !k.isEmpty else { return nil }
        self = k == "setup" ? .setup : .folder(k)
    }
}
