import AppKit
import DeweyCore
import Observation

enum Prefs {
    static let deweyPath = "deweyPath"
    static let layaServePath = "layaServePath"
    static let layaURL = "layaURL"
    static let startLayaOnLaunch = "startLayaOnLaunch"
    static let defaultLayaURL = "http://127.0.0.1:8000"

    static func register() {
        UserDefaults.standard.register(defaults: [startLayaOnLaunch: true, layaURL: defaultLayaURL])
    }
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
    var deweyURL: URL?
    var layaServeURL: URL?
    var appInfo: AppInfo?
    let laya: LayaController

    var cli: DeweyCLI? { deweyURL.map { DeweyCLI(executable: $0) } }
    var deweyReady: Bool { dewey.isOK }
    var everythingReady: Bool {
        if case .ready = laya.status { return dewey.isOK && layaServe.isOK }
        return false
    }

    var deweyFix: String { SetupCommands.installDewey(repo: RepoPath.url) }
    var layaFix: String { SetupCommands.installLaya }

    init() {
        Prefs.register()
        laya = LayaController(baseURL: Self.layaBaseURL())
    }

    static func layaBaseURL() -> URL {
        let s = UserDefaults.standard.string(forKey: Prefs.layaURL) ?? Prefs.defaultLayaURL
        return URL(string: s.trimmingCharacters(in: .whitespaces)) ?? URL(string: Prefs.defaultLayaURL)!
    }

    func launch() async {
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
        let locator = ToolLocator()
        async let foundDewey = locator.locate(.dewey, preferred: deweyPref)
        async let foundLaya = locator.locate(.layaServe, preferred: layaPref)

        deweyURL = await foundDewey
        appInfo = nil
        if let url = deweyURL {
            do {
                let info = try await DeweyCLI(executable: url).appInfo()
                appInfo = info
                if info.protocolVersion == AppInfo.supportedProtocol {
                    dewey = .ok("dewey \(info.version), Python \(info.python)\n\(url.path)")
                } else {
                    dewey = .problem("\(url.path) speaks app protocol \(info.protocolVersion); this app needs "
                                     + "\(AppInfo.supportedProtocol). Reinstall dewey from the checkout this app was built from.")
                }
            } catch {
                dewey = .problem("Found \(url.path), but it didn't answer `dewey app-info`. A dewey from before the "
                                 + "Mac app can't: reinstall it with the commands below.\n\(error.localizedDescription)")
            }
        } else {
            dewey = .problem(deweyPref.isEmpty
                             ? "dewey isn't in ~/.venvs/dewey, ~/.local/bin, Homebrew, or your shell's PATH."
                             : "The dewey path in Settings (\(deweyPref)) isn't an executable file.")
        }

        layaServeURL = await foundLaya
        if let url = layaServeURL {
            layaServe = .ok(url.path)
        } else {
            layaServe = .problem(layaPref.isEmpty
                                 ? "laya-serve isn't in ~/.venvs/laya, ~/.local/bin, Homebrew, or your shell's PATH. "
                                   + "Without it, plans use your rules and duplicates only."
                                 : "The laya-serve path in Settings (\(layaPref)) isn't an executable file.")
        }
        await laya.refresh()
    }

    func startLaya() async {
        guard let url = layaServeURL else { return }
        if !laya.isRunning { laya.baseURL = Self.layaBaseURL() }
        await laya.start(executable: url)
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
