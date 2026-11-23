import Foundation

public enum Tool: String, Sendable, CaseIterable {
    case dewey
    case layaServe = "laya-serve"
    /// What the Install Laya button runs.
    case uv

    /// The venv the README creates for this tool.
    var venv: String? {
        switch self {
        case .dewey: "dewey"
        case .layaServe: "laya"
        case .uv: nil
        }
    }
}

/// Finds `dewey`, `laya-serve` and `uv`: the app's own copy first, then the one its Install Laya
/// button set up, then the places the README installs them, then the person's login shell (apps
/// opened from Finder get a bare PATH).
public struct ToolLocator: Sendable {
    public var home: URL
    public var systemDirs: [URL]
    /// Tools inside the app (Dewey.app/Contents/Resources/bin, where build-app.sh puts dewey).
    public var bundledDir: URL?
    /// Where the Install Laya button puts laya-serve (`LayaInstaller.Layout.bin`).
    public var installedDir: URL?
    public var useLoginShell: Bool

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                systemDirs: [URL] = [URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin")],
                bundledDir: URL? = nil, installedDir: URL? = nil, useLoginShell: Bool = true) {
        self.home = home
        self.systemDirs = systemDirs
        self.bundledDir = bundledDir
        self.installedDir = installedDir
        self.useLoginShell = useLoginShell
    }

    public func candidates(for tool: Tool) -> [URL] {
        [bundledDir, installedDir].compactMap { $0?.appending(path: tool.rawValue) }
            + (tool.venv.map { [home.appending(path: ".venvs/\($0)/bin/\(tool.rawValue)")] } ?? [])
            + [home.appending(path: ".local/bin/\(tool.rawValue)")]
            + systemDirs.map { $0.appending(path: tool.rawValue) }
    }

    public static func isExecutable(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
            && FileManager.default.isExecutableFile(atPath: url.path)
    }

    /// A path chosen in Settings wins (and is nil if it isn't executable, so setup can say so).
    public func locate(_ tool: Tool, preferred: String? = nil) async -> URL? {
        if let preferred, !preferred.trimmingCharacters(in: .whitespaces).isEmpty {
            let url = URL(fileURLWithPath: (preferred as NSString).expandingTildeInPath)
            return Self.isExecutable(url) ? url : nil
        }
        if let found = candidates(for: tool).first(where: Self.isExecutable) { return found }
        return useLoginShell ? await loginShellLookup(tool.rawValue) : nil
    }

    /// `command -v NAME` in the person's login shell. The shell gets `limit` seconds and is then ended:
    /// a slow shell profile must not hang setup.
    ///
    /// Only the shell is waited for, never the end of what it prints. A profile that leaves a process
    /// running (`ssh-agent`, anything with `&`) hands it the shell's output pipe, and that pipe closes
    /// only when the process exits. 0.2.1 read to the end of the pipe, so it waited for that process
    /// too, after the 5 s as well, with the window on "Checking setup…" all the while.
    func loginShellLookup(_ name: String, shell: String? = nil, limit: TimeInterval = 5) async -> URL? {
        let shell = shell ?? ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-c", "command -v \(name)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let (done, cont) = AsyncStream<Void>.makeStream()
        p.terminationHandler = { _ in cont.finish() }
        guard (try? p.run()) != nil else { return nil }
        let output = PipeCollector(out.fileHandleForReading, keepLast: 65_536)
        let pid = p.processIdentifier
        let timeout = Task {
            try? await Task.sleep(for: .seconds(limit))
            if !Task.isCancelled { kill(pid, SIGKILL) }
        }
        for await _ in done {}  // the shell has exited, or the limit ended it
        timeout.cancel()
        let text = output.finish()
        let path = text.split(separator: "\n").last(where: { $0.hasPrefix("/") }).map(String.init)
        return path.map { URL(fileURLWithPath: $0) }.flatMap { Self.isExecutable($0) ? $0 : nil }
    }
}

/// The exact commands from the README, for the setup screen's Copy buttons.
public enum SetupCommands {
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `repo` is the dewey clone this app was built from, when known.
    public static func installDewey(repo: URL?) -> String {
        let target = repo.map { shellQuote($0.path + "[all]") } ?? "'./dewey[all]'"
        return """
        uv venv ~/.venvs/dewey --python 3.12
        uv pip install --python ~/.venvs/dewey/bin/python -e \(target)
        """
    }

    public static let installLaya = """
        uv venv ~/.venvs/laya --python \(LayaInstaller.pythonVersion)
        uv pip install --python ~/.venvs/laya/bin/python \(shellQuote(LayaInstaller.package))
        """

    public static let installUV = "brew install uv"
}
