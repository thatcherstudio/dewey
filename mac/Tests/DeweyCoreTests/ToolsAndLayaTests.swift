import Foundation
import Testing
@testable import DeweyCore

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "dewey-tools-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func makeFile(_ url: URL, executable: Bool, text: String = "#!/bin/sh\n") throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
}

struct ToolLocatorTests {
    @Test func prefersTheReadmeVenvThenLocalBin() async throws {
        let home = try tempDir()
        let locator = ToolLocator(home: home, systemDirs: [], useLoginShell: false)
        #expect(await locator.locate(.dewey) == nil)
        let local = home.appending(path: ".local/bin/dewey")
        try makeFile(local, executable: true)
        #expect(await locator.locate(.dewey) == local)
        let venv = home.appending(path: ".venvs/dewey/bin/dewey")
        try makeFile(venv, executable: true)
        #expect(await locator.locate(.dewey) == venv)
        #expect(await locator.locate(.layaServe) == nil)
        let laya = home.appending(path: ".venvs/laya/bin/laya-serve")
        try makeFile(laya, executable: true)
        #expect(await locator.locate(.layaServe) == laya)
    }

    @Test func skipsFilesThatArentExecutable() async throws {
        let home = try tempDir()
        try makeFile(home.appending(path: ".venvs/dewey/bin/dewey"), executable: false)
        let sys = home.appending(path: "brew-bin")
        try makeFile(sys.appending(path: "dewey"), executable: true)
        let locator = ToolLocator(home: home, systemDirs: [sys], useLoginShell: false)
        #expect(await locator.locate(.dewey) == sys.appending(path: "dewey"))
    }

    @Test func aChosenPathWinsAndABadOneIsNotIgnored() async throws {
        let home = try tempDir()
        try makeFile(home.appending(path: ".venvs/dewey/bin/dewey"), executable: true)
        let chosen = home.appending(path: "elsewhere/dewey")
        try makeFile(chosen, executable: true)
        let locator = ToolLocator(home: home, systemDirs: [], useLoginShell: false)
        #expect(await locator.locate(.dewey, preferred: chosen.path) == chosen)
        #expect(await locator.locate(.dewey, preferred: home.appending(path: "nope").path) == nil)
        #expect(await locator.locate(.dewey, preferred: "  ") == home.appending(path: ".venvs/dewey/bin/dewey"))
    }

    @Test func theAppsOwnCopyComesFirst() async throws {
        let home = try tempDir()
        let venv = home.appending(path: ".venvs/dewey/bin/dewey")
        try makeFile(venv, executable: true)
        let laya = home.appending(path: ".venvs/laya/bin/laya-serve")
        try makeFile(laya, executable: true)
        let bundled = home.appending(path: "Dewey.app/Contents/Resources/bin")
        try makeFile(bundled.appending(path: "dewey"), executable: true)
        let locator = ToolLocator(home: home, systemDirs: [], bundledDir: bundled, useLoginShell: false)
        #expect(await locator.locate(.dewey) == bundled.appending(path: "dewey"))
        #expect(await locator.locate(.layaServe) == laya, "laya-serve isn't in the app")
        #expect(await locator.locate(.dewey, preferred: venv.path) == venv, "a chosen path still wins")
    }

    @Test func installCommandsQuoteTheRepoPath() {
        let cmd = SetupCommands.installDewey(repo: URL(fileURLWithPath: "/Users/x/My Projects/dewey"))
        #expect(cmd.contains("-e '/Users/x/My Projects/dewey[all]'"))
        #expect(SetupCommands.shellQuote("it's") == #"'it'\''s'"#)
        #expect(SetupCommands.installDewey(repo: nil).contains("'./dewey[all]'"))
    }
}

struct LayaHealthTests {
    @Test func readsTheHealthPayload() {
        let body = Data(#"{"status": "ok", "loaded": ["english"], "device": "mps", "device_is_preference": false}"#.utf8)
        #expect(LayaController.interpret(data: body, statusCode: 200)
                == .ok(.init(loaded: ["english"], device: "mps")))
        #expect(LayaController.interpret(data: Data(#"{"status": "ok"}"#.utf8), statusCode: 200)
                == .ok(.init(loaded: [], device: nil)))  // a locked-down server answers liveness only
    }

    @Test func somethingElseOnThePortIsNotLaya() {
        #expect(LayaController.interpret(data: Data("<html>".utf8), statusCode: 404) == .other("HTTP 404"))
        if case .ok = LayaController.interpret(data: Data("<html>".utf8), statusCode: 200) {
            Issue.record("an HTML page is not laya-serve")
        }
    }

    @Test func nothingListeningIsRefused() async {
        #expect(await LayaController.probe(URL(string: "http://127.0.0.1:9")!) == .refused)
    }
}

/// A stand-in laya-serve: answers /health like the real one, on the env vars the app must set.
private let fakeLaya = #"""
#!/bin/sh
exec /usr/bin/python3 -c '
import http.server, json, os, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"status": "ok", "loaded": [os.environ["LAYA_MODELS"]], "device": "cpu"}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
print("fake laya on", os.environ["LAYA_HOST"], os.environ["LAYA_PORT"], flush=True)
http.server.HTTPServer((os.environ["LAYA_HOST"], int(os.environ["LAYA_PORT"])), H).serve_forever()
'
"""#

@MainActor @Suite(.timeLimit(.minutes(1)))
struct LayaControllerTests {
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"), "needs /usr/bin/python3"))
    func startsWaitsForHealthAndStops() async throws {
        let exe = try tempDir().appending(path: "laya-serve")
        try makeFile(exe, executable: true, text: fakeLaya)
        let port = Int.random(in: 20_000...40_000)
        let laya = LayaController(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        await laya.refresh()
        #expect(laya.status == .stopped)

        await laya.start(executable: exe)
        #expect(laya.isRunning && laya.ownsServer)
        try await waitFor(seconds: 10) { if case .ready = laya.status { true } else { false } }
        #expect(laya.status == .ready(.init(loaded: ["english"], device: "cpu")))
        try await waitFor(seconds: 2) { laya.log.contains("fake laya on 127.0.0.1 \(port)") }

        laya.stop()
        try await waitFor(seconds: 6) { laya.status == .stopped }
        #expect(!laya.isRunning)
        #expect(await LayaController.probe(laya.baseURL) == .refused)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"), "needs /usr/bin/python3"))
    func aServerItDidntStartIsUsedButNotOwned() async throws {
        let exe = try tempDir().appending(path: "laya-serve")
        try makeFile(exe, executable: true, text: fakeLaya)
        let port = Int.random(in: 40_001...60_000)
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let first = LayaController(baseURL: base)
        await first.start(executable: exe)
        try await waitFor(seconds: 10) { if case .ready = first.status { true } else { false } }

        let second = LayaController(baseURL: base)  // e.g. a laya-serve already running in Terminal
        await second.start(executable: exe)
        #expect(!second.isRunning && !second.ownsServer)
        if case .ready = second.status {} else { Issue.record("should use the running server: \(second.status)") }

        first.stopForQuit()  // waits up to 3 s for the process to go
        #expect(await LayaController.probe(base) == .refused)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"), "needs /usr/bin/python3"))
    func stopAndWaitReturnsOnceItsGone() async throws {
        let exe = try tempDir().appending(path: "laya-serve")
        try makeFile(exe, executable: true, text: fakeLaya)
        let laya = LayaController(baseURL: URL(string: "http://127.0.0.1:\(Int.random(in: 60_001...65_000))")!)
        await laya.start(executable: exe)
        #expect(laya.executable == exe)
        try await waitFor(seconds: 10) { if case .ready = laya.status { true } else { false } }

        await laya.stopAndWait()
        #expect(!laya.isRunning && laya.executable == nil)
        #expect(laya.status == .stopped)
        #expect(await LayaController.probe(laya.baseURL) == .refused)
    }

    // MARK: a server left behind (a crash, Force Quit)

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"), "needs /usr/bin/python3"))
    func theServerItStartsIsWrittenDownUntilItStops() async throws {
        let dir = try tempDir()
        let exe = dir.appending(path: "laya-serve"), record = dir.appending(path: "support/laya-serve.json")
        try makeFile(exe, executable: true, text: fakeLaya)
        let port = Int.random(in: 10_000...14_000)
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let laya = LayaController(baseURL: base, record: record)
        await laya.start(executable: exe)
        try await waitFor(seconds: 10) { if case .ready = laya.status { true } else { false } }
        let note = try #require(LayaController.read(record))
        let running = try #require(RunningProcess.find(note.pid))
        #expect(note.port == port && note.startSec == running.startSec && note.startUsec == running.startUsec)
        #expect(running.parent == getpid())

        // another Dewey opening now: the server has a living owner, so it and its note are left alone
        let second = LayaController(baseURL: base, record: record)
        #expect(await second.stopLeftover() == false)
        #expect(await LayaController.probe(base) == .ok(.init(loaded: ["english"], device: "cpu")))
        #expect(LayaController.read(record) == note)

        await laya.stopAndWait()
        #expect(!FileManager.default.fileExists(atPath: record.path))
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"), "needs /usr/bin/python3"))
    func aServerLeftByAnEarlierDeweyIsStoppedAtLaunch() async throws {
        let dir = try tempDir()
        let exe = dir.appending(path: "laya-serve"), record = dir.appending(path: "laya-serve.json")
        try makeFile(exe, executable: true, text: fakeLaya)
        let port = Int.random(in: 14_001...19_000)
        let base = URL(string: "http://127.0.0.1:\(port)")!

        // What a Dewey that crashed leaves: its laya-serve, now launchd's child, and the note about it.
        let sh = Process(), out = Pipe()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", "LAYA_HOST=127.0.0.1 LAYA_PORT=\(port) LAYA_MODELS=english \"$0\" >/dev/null 2>&1 & echo $!", exe.path]
        sh.standardOutput = out
        try sh.run()
        sh.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let pid = try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(pid, SIGKILL) }  // whatever the test finds, nothing outlives it
        try await waitFor(seconds: 10) { await LayaController.probe(base) != .refused }
        let orphan = try #require(RunningProcess.find(pid))
        #expect(orphan.parent == 1)
        try JSONEncoder().encode(ServerRecord(pid: pid, startSec: orphan.startSec, startUsec: orphan.startUsec, port: port))
            .write(to: record)

        let laya = LayaController(baseURL: base, record: record)
        #expect(await laya.stopLeftover())
        #expect(RunningProcess.find(pid) == nil)
        #expect(await LayaController.probe(base) == .refused)
        #expect(!FileManager.default.fileExists(atPath: record.path))
        #expect(laya.log.last?.contains("left running") == true)
        await laya.refresh()
        #expect(laya.status == .stopped)  // not "ready, started outside Dewey"
        #expect(await laya.stopLeftover() == false)
    }

    /// A pid is handed out again once its process is gone. The start time tells the two apart.
    @Test func aNoteThatNoLongerFitsItsProcessStopsNothing() async throws {
        let record = try tempDir().appending(path: "laya-serve.json")
        let me = try #require(RunningProcess.find(getpid()))
        for stale in [ServerRecord(pid: getpid(), startSec: me.startSec - 60, startUsec: me.startUsec, port: 8000),
                      ServerRecord(pid: 0x3FFF_FFF0, startSec: 1, startUsec: 1, port: 8000)] {
            try JSONEncoder().encode(stale).write(to: record)
            #expect(await LayaController(record: record).stopLeftover() == false)
            #expect(!FileManager.default.fileExists(atPath: record.path))
        }
        try Data("not json".utf8).write(to: record)
        #expect(await LayaController(record: record).stopLeftover() == false)
        #expect(await LayaController().stopLeftover() == false)  // no note kept: nothing to look for
    }

    private func waitFor(seconds: Double, _ condition: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("timed out after \(seconds) s")
    }
}
