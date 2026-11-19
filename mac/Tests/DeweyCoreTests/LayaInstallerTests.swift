import Foundation
import Testing
@testable import DeweyCore

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "dewey-install-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A stand-in uv. It records each call (with the env the installer must set) in ROOT/calls.log, and
/// makes what the real one would: a Python, a venv whose `python` plays the model download, a cache,
/// and laya-serve. A `fail-pip` or `slow-pip` file next to it changes what `pip install` does.
private let fakeUV = #"""
#!/bin/sh
root="$(dirname "$UV_PYTHON_INSTALL_DIR")"
here="$(dirname "$0")"
echo "uv $* | pref=$UV_PYTHON_PREFERENCE noconfig=$UV_NO_CONFIG cache=$UV_CACHE_DIR venv=$VIRTUAL_ENV" >> "$root/calls.log"
case "$1" in
python)
    mkdir -p "$UV_PYTHON_INSTALL_DIR/cpython-3.11"
    head -c 1000 /dev/zero > "$UV_PYTHON_INSTALL_DIR/cpython-3.11/lib" ;;
venv)
    mkdir -p "$2/bin"
    cat > "$2/bin/python" <<'PY'
#!/bin/sh
echo "python $1 | hf=$HF_HOME" >> "$(dirname "$HF_HOME")/calls.log"
echo '{"total": 2000}'
echo '{"bar": 1, "bytes": 500}'
echo '{"bar": 2, "bytes": 2000}'
echo "Warning: You are sending unauthenticated requests to the HF Hub." >&2
echo '{"path": "/snapshot"}'
PY
    chmod 755 "$2/bin/python" ;;
pip)
    [ -e "$here/slow-pip" ] && exec sleep 30
    if [ -e "$here/fail-pip" ]; then
        echo "error: Failed to fetch: https://pypi.org/simple/laya/" >&2
        echo "  Caused by: Could not connect, are you offline?" >&2
        exit 1
    fi
    mkdir -p "$UV_CACHE_DIR"
    head -c 3000 /dev/zero > "$UV_CACHE_DIR/wheel"
    venv="$(dirname "$(dirname "$4")")"
    printf '#!/bin/sh\necho "HF_HOME=$HF_HOME args=$*"\n' > "$venv/bin/laya-serve"
    chmod 755 "$venv/bin/laya-serve"
    echo "Installed 1 package" >&2 ;;
esac
"""#

private func makeUV(in dir: URL) throws -> URL {
    let uv = dir.appending(path: "uv")
    try fakeUV.write(to: uv, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: uv.path)
    return uv
}

private func run(_ exe: URL, _ args: [String]) throws -> String {
    let p = Process()
    p.executableURL = exe
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    try p.run()
    p.waitUntilExit()
    return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}

@MainActor @Suite(.timeLimit(.minutes(1)))
struct LayaInstallerTests {
    @Test func installsAllThreeStepsThenWritesTheWrapper() async throws {
        let dir = try tempDir()
        let uv = try makeUV(in: dir)
        let layout = LayaInstaller.Layout(root: dir.appending(path: "Dewey/Laya"))
        let installer = LayaInstaller(layout: layout)
        await installer.install(uv: uv)

        #expect(installer.state == .finished)
        #expect(installer.fraction == 1)
        let calls = try String(contentsOf: layout.root.appending(path: "calls.log"), encoding: .utf8)
        let env = "pref=only-managed noconfig=1 cache=\(layout.cache.path) venv="
        #expect(calls.contains("uv python install 3.11 --no-bin | \(env)"))
        #expect(calls.contains("uv venv \(layout.venv.path) --python 3.11 --clear | \(env)"))
        #expect(calls.contains("uv pip install --python \(layout.venv.path)/bin/python laya[serve] | \(env)"))
        #expect(calls.contains("python -I | hf=\(layout.huggingface.path)"))
        #expect(installer.stepTotal == 2000 && installer.stepBytes == 2000, "the model step reads the script's bytes")
        #expect(installer.log.contains("Warning: You are sending unauthenticated requests to the HF Hub."))
        #expect(!installer.log.contains { $0.hasPrefix("{") }, "the script's JSON lines aren't log lines")

        #expect(ToolLocator.isExecutable(layout.layaServe))
        #expect(try run(layout.layaServe, ["--x"]) == "HF_HOME=\(layout.huggingface.path) args=--x\n")
        #expect(!FileManager.default.fileExists(atPath: layout.cache.path), "uv's cache goes once it's installed")
        let backup = try layout.root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        #expect(backup == true)
    }

    @Test func aFailedStepSaysWhyAndLeavesNoLayaServe() async throws {
        let dir = try tempDir()
        let uv = try makeUV(in: dir)
        try Data().write(to: dir.appending(path: "fail-pip"))
        let installer = LayaInstaller(layout: .init(root: dir.appending(path: "Laya")))
        await installer.install(uv: uv)

        #expect(installer.state == .failed("Couldn't install Laya: Could not connect, are you offline?"))
        #expect(!FileManager.default.fileExists(atPath: installer.layout.layaServe.path))
        #expect(FileManager.default.fileExists(atPath: installer.layout.python.path), "a retry keeps what it got")
        #expect(installer.fraction < LayaInstaller.start(of: .model))
    }

    @Test func cancelStopsTheRunningStep() async throws {
        let dir = try tempDir()
        let uv = try makeUV(in: dir)
        try Data().write(to: dir.appending(path: "slow-pip"))
        let installer = LayaInstaller(layout: .init(root: dir.appending(path: "Laya")))
        let started = Date()
        let install = Task { await installer.install(uv: uv) }
        while installer.state != .running(.packages) && Date().timeIntervalSince(started) < 10 {
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(300))  // into `pip install`, the 30 s sleep
        installer.cancel()
        await install.value

        #expect(installer.state == .cancelled)
        #expect(Date().timeIntervalSince(started) < 10, "it didn't wait for the step to end")
        #expect(!FileManager.default.fileExists(atPath: installer.layout.layaServe.path))
    }

    @Test func notEnoughSpaceStopsBeforeDownloading() async throws {
        let dir = try tempDir()
        let installer = LayaInstaller(layout: .init(root: dir.appending(path: "Laya")))
        installer.requiredFreeBytes = .max
        await installer.install(uv: try makeUV(in: dir))
        guard case .failed(let why) = installer.state else {
            Issue.record("expected a failure, got \(installer.state)")
            return
        }
        #expect(why.hasPrefix("Installing Laya needs about"))
        #expect(!FileManager.default.fileExists(atPath: installer.layout.root.appending(path: "calls.log").path))
    }

    @Test func readsTheModelScriptsLines() {
        var p = LayaInstaller.ModelProgress()
        let read = [
            #"{"total": 846195574}"#,
            #"{"bar": 4446495568, "bytes": 138789422}"#,
            #"{"bar": 4483342672, "bytes": 745}"#,
            "Warning: You are sending unauthenticated requests to the HF Hub.",
            #"{"path": "/x/snapshots/e333"}"#,
        ].map { p.read($0) }
        #expect(read == [true, true, true, false, true])
        #expect(p.total == 846_195_574 && p.bytes == 138_789_422, "the furthest of the two counters")
        #expect(p.path == "/x/snapshots/e333")
    }

    @Test func dropsWhatWouldSendUVOrPythonElsewhere() {
        let env = LayaInstaller.cleanEnvironment([
            "PATH": "/usr/bin", "HOME": "/Users/x", "UV_INDEX_URL": "https://mirror", "VIRTUAL_ENV": "/v",
            "PYTHONPATH": "/p", "HF_HOME": "/h", "CONDA_PREFIX": "/c",
        ])
        #expect(env == ["PATH": "/usr/bin", "HOME": "/Users/x"])
        #expect(LayaInstaller.reason(["error: Failed to fetch", "  Caused by: dns error", ""]) == "dns error")
        #expect(LayaInstaller.reason([]) == "no output")
    }

    @Test func theBarAddsUpToOne() {
        #expect(LayaInstaller.start(of: .python) == 0)
        let total = LayaInstaller.Step.allCases.reduce(0) { $0 + $1.weight }
        #expect(abs(total - 1) < 1e-9)
    }

    @Test func removeDeletesTheInstallAndNothingElse() async throws {
        let dir = try tempDir()
        let layout = LayaInstaller.Layout(root: dir.appending(path: "Laya"))
        let installer = LayaInstaller(layout: layout)
        await installer.install(uv: try makeUV(in: dir))
        try #require(installer.state == .finished)
        let mine = layout.bin.appending(path: "mine")  // a root pointed at the wrong folder: not the installer's
        try Data("mine".utf8).write(to: mine)
        #expect(await installer.diskUsage() > 0)

        try await installer.remove()
        let fm = FileManager.default
        for url in [layout.layaServe, layout.venv, layout.python, layout.huggingface] {
            #expect(!fm.fileExists(atPath: url.path), "\(url.lastPathComponent) is gone")
        }
        #expect(fm.fileExists(atPath: mine.path))
        #expect(fm.fileExists(atPath: layout.root.appending(path: "calls.log").path))
        #expect(installer.state == .idle && installer.fraction == 0 && installer.log.isEmpty)
        #expect(installer.startedAt == nil && !installer.isRemoving)
        #expect(await installer.diskUsage() == 0)
    }

    @Test func removeTakesWhatAStoppedInstallLeftAndItsFolder() async throws {
        let dir = try tempDir()
        let layout = LayaInstaller.Layout(root: dir.appending(path: "Dewey/Laya"))
        let fm = FileManager.default
        for url in [layout.python.appending(path: "x"), layout.cache.appending(path: "y"),
                    layout.bin.appending(path: ".laya-serve.tmp"), layout.root.appending(path: ".DS_Store")] {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: 1000).write(to: url)
        }
        let installer = LayaInstaller(layout: layout)
        #expect(await installer.diskUsage() == 2000, "bin's temp file and .DS_Store aren't counted")

        try await installer.remove()
        #expect(!fm.fileExists(atPath: layout.root.path))
        #expect(fm.fileExists(atPath: dir.appending(path: "Dewey").path))
    }

    @Test func removeWaitsForNoInstall() async throws {
        let dir = try tempDir()
        let uv = try makeUV(in: dir)
        try Data().write(to: dir.appending(path: "slow-pip"))
        let installer = LayaInstaller(layout: .init(root: dir.appending(path: "Laya")))
        let started = Date()
        let install = Task { await installer.install(uv: uv) }
        while installer.state != .running(.packages) && Date().timeIntervalSince(started) < 10 {
            try await Task.sleep(for: .milliseconds(50))
        }
        try await installer.remove()
        #expect(FileManager.default.fileExists(atPath: installer.layout.python.path), "not under a running uv")
        installer.cancel()
        await install.value
    }
}

struct InstalledLayaLocatorTests {
    @Test func theInstalledLayaComesAfterTheAppsOwnAndBeforeTheReadmeVenv() async throws {
        let home = try tempDir()
        let venv = home.appending(path: ".venvs/laya/bin/laya-serve")
        let installed = home.appending(path: "Library/Application Support/Dewey/Laya/bin")
        let bundled = home.appending(path: "Dewey.app/Contents/Resources/bin")
        for url in [venv, installed.appending(path: "laya-serve"), bundled.appending(path: "uv")] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let locator = ToolLocator(home: home, systemDirs: [], bundledDir: bundled, installedDir: installed,
                                  useLoginShell: false)
        #expect(await locator.locate(.layaServe) == installed.appending(path: "laya-serve"))
        #expect(await locator.locate(.uv) == bundled.appending(path: "uv"))
        #expect(!locator.candidates(for: .uv).contains { $0.path.contains(".venvs") })
        #expect(SetupCommands.installLaya.contains("uv pip install --python ~/.venvs/laya/bin/python 'laya[serve]'"))
    }
}

/// The real thing, end to end: about 1.7 GB from PyPI and Hugging Face into a temporary folder, then
/// laya-serve from it until /health answers. Opt in with DEWEY_TEST_LAYA_INSTALL=1 (it takes 5 to 15
/// minutes); DEWEY_TEST_UV picks the uv (default: Homebrew's).
private let realUV: URL? = {
    guard ProcessInfo.processInfo.environment["DEWEY_TEST_LAYA_INSTALL"] == "1" else { return nil }
    let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DEWEY_TEST_UV"] ?? "/opt/homebrew/bin/uv")
    return ToolLocator.isExecutable(url) ? url : nil
}()

@MainActor @Suite(.timeLimit(.minutes(30)))
struct RealLayaInstallTests {
    @Test(.enabled(if: realUV != nil, "set DEWEY_TEST_LAYA_INSTALL=1 (downloads about 1.7 GB)"))
    func installsAndServes() async throws {
        let root = try ProcessInfo.processInfo.environment["DEWEY_TEST_LAYA_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? tempDir().appending(path: "Laya")
        let installer = LayaInstaller(layout: .init(root: root))
        let progress = Task { @MainActor in
            var last = -1.0
            while !Task.isCancelled {
                if installer.fraction - last >= 0.05 {
                    last = installer.fraction
                    print("install: \(installer.state) \(Int(last * 100))% \(LayaInstaller.size(installer.stepBytes))")
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        await installer.install(uv: realUV!)
        progress.cancel()
        #expect(installer.state == .finished, "\(installer.log.suffix(20).joined(separator: "\n"))")

        let hub = installer.layout.huggingface.appending(path: "hub")
        let model = LayaInstaller.size(of: hub)
        let laya = LayaController(baseURL: URL(string: "http://127.0.0.1:\(Int.random(in: 20_000...40_000))")!)
        await laya.start(executable: installer.layout.layaServe)
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if case .ready = laya.status { break }
            if case .failed = laya.status { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        print("laya: \(laya.status)")
        if case .ready(let h) = laya.status { #expect(h.loaded == ["english"]) } else {
            Issue.record("laya-serve didn't come up: \(laya.status)\n\(laya.log.suffix(20).joined(separator: "\n"))")
        }
        laya.stopForQuit()
        // laya-serve still prints "Fetching 5 files", its check of the cache, but downloads nothing.
        #expect(LayaInstaller.size(of: hub) == model, "the model was there already")
    }
}
