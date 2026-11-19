import Foundation
import Observation

/// Installs Laya for the app, the way the README's two `uv` lines do, but into one folder of Dewey's
/// own (`~/Library/Application Support/Dewey/Laya`), with progress, and with the model downloaded up
/// front so laya-serve's first start doesn't stall on it.
///
/// Three steps: Python 3.11 (uv's standalone build), Laya and PyTorch into a venv, then Laya's
/// English model from Hugging Face. The last thing written is `bin/laya-serve`, a wrapper that points
/// HF_HOME at that model and runs the venv's laya-serve. ToolLocator looks for that wrapper, so an
/// install only counts once it finished. A failed or cancelled install keeps what it downloaded
/// (uv's cache, a partial model), so trying again picks up from there. `remove()` deletes it all.
@MainActor @Observable
public final class LayaInstaller {
    /// Where everything goes. `remove()` deletes it.
    public struct Layout: Sendable, Equatable {
        public var root: URL

        public init(root: URL) { self.root = root }

        public static var standard: Layout {
            Layout(root: FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/Dewey/Laya"))
        }

        public var bin: URL { root.appending(path: "bin") }
        /// The app's note of the laya-serve it is running (`LayaController.stopLeftover`). Beside the
        /// install, not in it: Remove Laya must not take the note of a server that is still up.
        public var serverRecord: URL { root.deletingLastPathComponent().appending(path: "laya-serve.json") }
        /// The wrapper the app runs. It exists only once an install has finished.
        public var layaServe: URL { bin.appending(path: Tool.layaServe.rawValue) }
        /// uv's managed Pythons (UV_PYTHON_INSTALL_DIR), so the venv never depends on one Homebrew upgrades.
        public var python: URL { root.appending(path: "python") }
        public var venv: URL { root.appending(path: "venv") }
        /// HF_HOME: the model.
        public var huggingface: URL { root.appending(path: "huggingface") }
        /// uv's cache, deleted once an install finishes.
        public var cache: URL { root.appending(path: "uv-cache") }
        /// The folders an install makes, which `remove()` deletes whole. `bin` is not one of them:
        /// only the wrapper in it is the installer's.
        var parts: [URL] { [venv, python, huggingface, cache] }
    }

    public enum Step: Int, CaseIterable, Sendable {
        case python, packages, model

        public var title: String {
            switch self {
            case .python: "Python \(LayaInstaller.pythonVersion)"
            case .packages: "Laya and PyTorch"
            case .model: "Laya's English model"
            }
        }

        /// Its share of the progress bar, about its share of the bytes.
        var weight: Double {
            switch self {
            case .python: 0.05
            case .packages: 0.45
            case .model: 0.50
            }
        }

        /// What the step usually writes, measured on 2026-11-18: Python 3.11.18 is 74 MB unpacked, and
        /// laya 0.4.37 with PyTorch 2.15 fills uv's cache with 750 MB. The model's size comes from the Hub.
        var estimate: Int64? {
            switch self {
            case .python: 75_000_000
            case .packages: 750_000_000
            case .model: nil
            }
        }
    }

    public enum State: Equatable, Sendable {
        case idle
        case running(Step)
        case finished
        case failed(String)
        case cancelled
    }

    public nonisolated static let pythonVersion = "3.11"

    // What Install Laya downloads is fixed here, so the button installs what this version of the app
    // was tried with and not whatever was published this morning. To move to a newer Laya, change
    // all three together and run a real install.
    /// The release of the package the README installs.
    public nonisolated static let layaVersion = "0.4.37"
    public nonisolated static let package = "laya[serve]==\(layaVersion)"
    /// Laya's own dependencies (PyTorch, transformers, FastAPI…) as they were on this day: nothing
    /// uploaded to PyPI later is installed (uv's --exclude-newer). Later than the Laya release above.
    public nonisolated static let packagesAsOf = "2026-11-19T00:00:00Z"
    /// The commit of the model on Hugging Face: the one Laya \(layaVersion) lists as reviewed
    /// (`laya/revisions.py`, PINNED_REVISIONS), which is what LAYA_REVISION=reviewed in the wrapper
    /// makes laya-serve load. A commit names its files exactly; "main" names whatever is newest.
    public nonisolated static let modelRevision = "55cf4c4ebb4ebe31b2550e8bdf3bd21b99753851"

    public private(set) var state: State = .idle
    /// 0...1 across all three steps.
    public private(set) var fraction: Double = 0
    /// Bytes the current step has written (downloaded, for the model) and what it expects in all.
    public private(set) var stepBytes: Int64 = 0
    public private(set) var stepTotal: Int64?
    public private(set) var startedAt: Date?
    /// The last 200 lines uv and the model download printed.
    public private(set) var log: [String] = []
    /// `remove()` is deleting the install.
    public private(set) var isRemoving = false
    public let layout: Layout
    /// Python, the venv, uv's cache and the model take about 1.8 GB while installing.
    public var requiredFreeBytes: Int64 = 2_500_000_000

    private var process: Process?
    private var cancelled = false
    private var model = ModelProgress()

    public init(layout: Layout = .standard) {
        self.layout = layout
    }

    public var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// Runs all three steps with `uv` and returns when they finished, failed or were cancelled.
    public func install(uv: URL) async {
        guard !isRunning else { return }
        cancelled = false
        log = []
        fraction = 0
        startedAt = .now
        do {
            try await prepare()
            for step in Step.allCases {
                guard !cancelled else { throw Stop.cancelled }
                state = .running(step)
                stepBytes = 0
                stepTotal = step.estimate
                fraction = Self.start(of: step)
                try await run(step, uv: uv)
            }
            try writeWrapper()
            try? FileManager.default.removeItem(at: layout.cache)
            fraction = 1
            state = .finished
        } catch Stop.cancelled {
            state = .cancelled
        } catch let e as Failure {
            state = .failed(e.message)
        } catch {
            state = .failed(error.localizedDescription)
        }
        process = nil
    }

    /// SIGTERM to what's running. `install` then returns with `.cancelled`.
    public func cancel() {
        guard isRunning else { return }
        cancelled = true
        process?.terminate()
    }

    /// Deletes what an install put in `layout` (finished or not) and forgets how the last one went.
    /// The wrapper goes first, so nothing finds a half-deleted Laya. It deletes only its own folders
    /// and files, and `root` once that leaves it empty, so a `root` pointed at the wrong folder loses
    /// nothing else. Stop the laya-serve it set up first.
    public func remove() async throws {
        guard !isRunning, !isRemoving else { return }
        isRemoving = true
        defer { isRemoving = false }
        let layout = layout
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let files = [layout.layaServe, layout.bin.appending(path: ".laya-serve.tmp")]
            for url in files + layout.parts where fm.fileExists(atPath: url.path) {
                do {
                    try fm.removeItem(at: url)
                } catch {
                    throw Failure(message: "Couldn't remove \(url.path): \(error.localizedDescription)")
                }
            }
            for dir in [layout.bin, layout.root] {
                let left = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? ["?"]
                if left.allSatisfy({ $0 == ".DS_Store" }) { try? fm.removeItem(at: dir) }
            }
        }.value
        state = .idle
        fraction = 0
        stepBytes = 0
        stepTotal = nil
        startedAt = nil
        log = []
    }

    /// What `remove()` would free: 0 when nothing is installed.
    public func diskUsage() async -> Int64 {
        await Self.bytes(in: [layout.layaServe] + layout.parts)
    }

    /// App quit: stop the download and wait up to 2 s, so it never outlives the app.
    public func stopForQuit() {
        cancel()
        guard let p = process else { return }
        let deadline = Date().addingTimeInterval(2)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }

    // MARK: - steps

    private enum Stop: Error { case cancelled }

    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    private func prepare() async throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: layout.root, withIntermediateDirectories: true)
        } catch {
            throw Failure(message: "Couldn't make \(layout.root.path): \(error.localizedDescription)")
        }
        // All of it downloads again, so Time Machine needn't keep it.
        var root = layout.root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)

        let have = await Self.bytes(in: [layout.root])  // a retry needs less
        let free = (try? layout.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        if let free, free < requiredFreeBytes - have {
            throw Failure(message: "Installing Laya needs about \(Self.size(requiredFreeBytes - have)) of free space, "
                          + "and this disk has \(Self.size(free)). Free some up, then try again.")
        }
    }

    private func run(_ step: Step, uv: URL) async throws {
        switch step {
        case .python:
            try await measured(step, dirs: [layout.python]) {
                try await self.exec(uv, ["python", "install", Self.pythonVersion, "--no-bin"], env: self.uvEnvironment)
            }
        case .packages:
            let python = layout.venv.appending(path: "bin/python")
            try await measured(step, dirs: [layout.cache]) {
                try await self.exec(uv, ["venv", self.layout.venv.path, "--python", Self.pythonVersion, "--clear"],
                                    env: self.uvEnvironment)
                try await self.exec(uv, ["pip", "install", "--python", python.path, Self.package,
                                         "--exclude-newer", Self.packagesAsOf],
                                    env: self.uvEnvironment)
            }
            guard ToolLocator.isExecutable(layout.venv.appending(path: "bin/laya-serve")) else {
                throw Failure(message: "Laya installed, but it has no laya-serve.")
            }
        case .model:
            model = ModelProgress()
            try await exec(layout.venv.appending(path: "bin/python"),
                           ["-I", "-c", Self.modelScript, Self.modelRevision],
                           env: modelEnvironment) { line in
                guard self.model.read(line) else { return false }
                self.stepTotal = self.model.total
                self.stepBytes = self.model.bytes
                if let total = self.model.total, total > 0 {
                    self.advance(step, part: Double(self.model.bytes) / Double(total))
                }
                return true
            }
        }
    }

    /// Runs `body` while a poller turns the growth of `dirs` into the step's progress.
    private func measured(_ step: Step, dirs: [URL], _ body: () async throws -> Void) async throws {
        let base = await Self.bytes(in: dirs)
        let poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let now = await Self.bytes(in: dirs)
                guard let self, !Task.isCancelled else { return }
                self.stepBytes = max(0, now - base)
                if let estimate = step.estimate { self.advance(step, part: Double(self.stepBytes) / Double(estimate)) }
            }
        }
        defer { poll.cancel() }
        try await body()
    }

    /// The bar never goes back, and a step only shows as done when it is.
    private func advance(_ step: Step, part: Double) {
        fraction = max(fraction, Self.start(of: step) + step.weight * min(max(part, 0), 0.99))
    }

    static func start(of step: Step) -> Double {
        Step.allCases.prefix(while: { $0 != step }).reduce(0) { $0 + $1.weight }
    }

    /// One command, to the end. Lines go to the log, except stdout lines `onStdout` takes (it returns true).
    private func exec(_ exe: URL, _ args: [String], env: [String: String],
                      onStdout: (@MainActor (String) -> Bool)? = nil) async throws {
        guard !cancelled else { throw Stop.cancelled }
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.environment = env
        p.currentDirectoryURL = layout.root  // never a project folder whose uv.toml or pyproject.toml uv would read
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let (done, cont) = AsyncStream<Int32>.makeStream()
        p.terminationHandler = { proc in
            cont.yield(proc.terminationStatus)
            cont.finish()
        }
        do {
            try p.run()
        } catch {
            throw Failure(message: "Couldn't run \(exe.path): \(error.localizedDescription)")
        }
        process = p
        let outLines = PipeReader.lines(out.fileHandleForReading)
        let errLines = PipeReader.lines(err.fileHandleForReading)
        let readOut = Task { [weak self] in
            for await line in outLines where onStdout?(line) != true { self?.append(line) }
        }
        let readErr = Task { [weak self] in
            for await line in errLines { self?.append(line) }
        }
        var code: Int32 = -1
        for await c in done { code = c }
        process = nil
        // Cancelled: don't wait for the pipes, which a child of uv (a build) might still hold open.
        guard !cancelled else { throw Stop.cancelled }
        await readOut.value
        await readErr.value
        guard code == 0 else {
            let what = switch state {
            case .running(.python): "Couldn't get Python \(Self.pythonVersion)"
            case .running(.model): "Couldn't download the model"
            default: "Couldn't install Laya"
            }
            throw Failure(message: "\(what): \(Self.reason(log))")
        }
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    /// The last thing written: until it exists, nothing finds this install.
    private func writeWrapper() throws {
        let q = SetupCommands.shellQuote
        let script = """
            #!/bin/sh
            # laya-serve as Dewey's Install Laya button set it up, with the model in the folder next to
            # this one. Deleting \(layout.root.path) removes Laya and the model.
            export HF_HOME=\(q(layout.huggingface.path))
            export HF_HUB_DISABLE_TELEMETRY=1
            # Load the model commit this Laya lists as reviewed (the one Install Laya downloaded),
            # not whatever is newest on Hugging Face.
            export LAYA_REVISION="${LAYA_REVISION:-reviewed}"
            exec \(q(layout.venv.appending(path: "bin/laya-serve").path)) "$@"

            """
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: layout.bin, withIntermediateDirectories: true)
            let tmp = layout.bin.appending(path: ".laya-serve.tmp")
            try Data(script.utf8).write(to: tmp)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
            if fm.fileExists(atPath: layout.layaServe.path) { try fm.removeItem(at: layout.layaServe) }
            try fm.moveItem(at: tmp, to: layout.layaServe)
        } catch {
            throw Failure(message: "Couldn't write \(layout.layaServe.path): \(error.localizedDescription)")
        }
    }

    // MARK: - environment

    /// The app's environment without anything that would point uv, Python or Hugging Face elsewhere
    /// (when it was opened from a Terminal with a venv active, say).
    nonisolated static func cleanEnvironment(_ base: [String: String]) -> [String: String] {
        base.filter { key, _ in
            !(key.hasPrefix("UV_") || key.hasPrefix("PYTHON") || key.hasPrefix("HF_") || key.hasPrefix("CONDA")
              || key == "VIRTUAL_ENV" || key == "HUGGING_FACE_HUB_TOKEN")
        }
    }

    var uvEnvironment: [String: String] {
        var env = Self.cleanEnvironment(ProcessInfo.processInfo.environment)
        env["UV_PYTHON_INSTALL_DIR"] = layout.python.path
        env["UV_PYTHON_PREFERENCE"] = "only-managed"
        env["UV_CACHE_DIR"] = layout.cache.path
        env["UV_NO_CONFIG"] = "1"
        env["UV_NO_PROGRESS"] = "1"
        return env
    }

    var modelEnvironment: [String: String] {
        var env = Self.cleanEnvironment(ProcessInfo.processInfo.environment)
        env["HF_HOME"] = layout.huggingface.path
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        return env
    }

    // MARK: - model download

    /// Downloads exactly what laya-serve loads for `english` (laya's `Agent.__init__`: the repo's root
    /// checkpoint, filtered to these patterns, at the commit given as its argument) and prints JSON lines for the progress
    /// bar: `{"total": bytes}` first, then `{"bar": id, "bytes": n}` from huggingface_hub's byte
    /// counters, and `{"path": snapshot}` at the end. Xet writes the file only at the end, so the bytes
    /// have to come from those counters rather than from the folder.
    static let modelScript = #"""
        import fnmatch, json, os, sys, time
        from huggingface_hub import HfApi, snapshot_download
        from tqdm import tqdm

        REPO = "convaiinnovations/laya"
        REVISION = sys.argv[1]
        PATTERNS = ["rl_agent_config.json", "model.safetensors", "tokenizer/*", "encoder/*"]
        DEVNULL = open(os.devnull, "w")

        def say(**kw):
            print(json.dumps(kw), flush=True)

        class Report(tqdm):
            def __init__(self, *args, **kwargs):
                kwargs.pop("name", None)
                kwargs.update(file=DEVNULL, disable=False)
                super().__init__(*args, **kwargs)
                self._said = 0.0

            def update(self, n=1):
                shown = super().update(n)
                if self.unit == "B" and time.monotonic() - self._said >= 0.25:
                    self._said = time.monotonic()
                    say(bar=id(self), bytes=int(self.n))
                return shown

            def close(self):
                if self.unit == "B":
                    say(bar=id(self), bytes=int(self.n))
                super().close()

        info = HfApi().model_info(REPO, revision=REVISION, files_metadata=True)
        say(total=sum(s.size or 0 for s in info.siblings if any(fnmatch.fnmatch(s.rfilename, p) for p in PATTERNS)))
        say(path=snapshot_download(REPO, revision=REVISION, allow_patterns=PATTERNS, tqdm_class=Report))
        """#

    /// Reads the model script's JSON lines.
    struct ModelProgress {
        var total: Int64?
        var bars: [Int64: Int64] = [:]
        var path: String?

        /// The furthest counter: network bytes for a Xet download, bytes written for a plain one.
        var bytes: Int64 { bars.values.max() ?? 0 }

        /// False for a line that isn't one of the script's (a warning, say).
        mutating func read(_ line: String) -> Bool {
            guard line.hasPrefix("{"),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                return false
            }
            if let t = (obj["total"] as? NSNumber)?.int64Value { total = t }
            if let bar = (obj["bar"] as? NSNumber)?.int64Value, let n = (obj["bytes"] as? NSNumber)?.int64Value {
                bars[bar] = n
            }
            if let p = obj["path"] as? String { path = p }
            return true
        }
    }

    // MARK: - helpers

    /// The last thing printed, which for uv is the cause ("Could not connect, are you offline?") and
    /// for Python the exception.
    nonisolated static func reason(_ lines: [String]) -> String {
        let last = lines.map { $0.trimmingCharacters(in: .whitespaces) }.last(where: { !$0.isEmpty }) ?? "no output"
        return last.hasPrefix("Caused by: ") ? String(last.dropFirst("Caused by: ".count)) : last
    }

    public nonisolated static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// The size of every file under `dirs`, counted off the main thread (uv's cache holds ~20,000 files).
    nonisolated static func bytes(in dirs: [URL]) async -> Int64 {
        await Task.detached(priority: .utility) { dirs.reduce(0) { $0 + size(of: $1) } }.value
    }

    nonisolated static func size(of dir: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        if let v = try? dir.resourceValues(forKeys: keys), v.isRegularFile == true { return Int64(v.fileSize ?? 0) }
        guard let walk = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walk {
            let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
        }
        return total
    }
}
