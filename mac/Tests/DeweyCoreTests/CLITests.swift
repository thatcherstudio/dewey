import Foundation
import Testing
@testable import DeweyCore

/// A stand-in `dewey` (a shell script) so the runner is tested without Python.
private let fakeDewey = #"""
#!/bin/sh
case "$1" in
  app-info)
    echo '{"event": "log", "text": "hello"}'
    echo '{"event": "result", "data": {"version": "9.9.9", "protocol": 1, "python": "3.12.0", "executable": "/x"}}' ;;
  last-arg)
    for a in "$@"; do last="$a"; done
    echo "{\"event\": \"result\", \"data\": {\"value\": \"$last\"}}" ;;
  echo-stdin)
    read -r line
    echo "{\"event\": \"result\", \"data\": $line}" ;;
  fail)
    echo '{"event": "error", "code": "nothing_to_undo", "message": "nothing to undo"}'
    exit 1 ;;
  crash)
    echo 'Traceback (most recent call last): boom' >&2
    exit 3 ;;
  deaf)
    echo '{"event": "error", "code": "config", "message": "broken settings"}'
    exit 1 ;;
  noisy)
    i=0; while [ $i -lt 3000 ]; do echo "stderr line $i padding padding padding padding" >&2; i=$((i+1)); done
    echo '{"event": "result", "data": {"value": "survived"}}' ;;
  stuck|apply)
    # Doesn't hear Ctrl-C or SIGTERM. "stuck" never ends by itself; "apply" finishes its move a moment later.
    trap '' INT TERM
    echo '{"event": "progress", "phase": "hash", "label": "Hashing", "unit": "files", "n": 0, "total": 9, "bytes": 0, "total_bytes": null, "rate": 0, "elapsed": 0, "eta": null, "extra": "", "done": false}'
    i=0; while [ "$1" = stuck ] || [ $i -lt 20 ]; do sleep 0.05; i=$((i+1)); done
    echo '{"event": "result", "data": {"value": "moved"}}' ;;
  slow)
    trap 'echo "{\"event\": \"interrupted\", \"batch\": \"b1\", \"message\": \"stopped\"}"; exit 130' INT
    echo '{"event": "progress", "phase": "decide", "label": "Deciding", "unit": "files", "n": 0, "total": 9, "bytes": 0, "total_bytes": null, "rate": 0, "elapsed": 0, "eta": null, "extra": "", "done": false}'
    while :; do sleep 0.05; done ;;
esac
"""#

private struct Value: Decodable, Sendable, Equatable { var value: String }
private struct Count: Decodable, Sendable, Equatable { var n: Int }

private func makeFake() throws -> DeweyCLI {
    let dir = FileManager.default.temporaryDirectory.appending(path: "dewey-fake-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appending(path: "dewey")
    try fakeDewey.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return DeweyCLI(executable: url)
}

private actor Collected {
    var events: [DeweyEvent] = []
    func add(_ e: DeweyEvent) { events.append(e) }
}

@Suite(.timeLimit(.minutes(1)))
struct CLITests {
    @Test func decodesTheResultAndPassesEveryEvent() async throws {
        let cli = try makeFake()
        let seen = Collected()
        let info = try await cli.run(["app-info"], as: AppInfo.self) { await seen.add($0) }
        #expect(info.version == "9.9.9")
        let events = await seen.events
        #expect(events.first == .log("hello"))
        #expect(events.count == 2)
    }

    @Test func alwaysAddsJsonFlag() async throws {
        let v = try await makeFake().run(["last-arg", "/some/root"], as: Value.self)
        #expect(v.value == "--json")
    }

    @Test func sendsStdin() async throws {
        let c = try await makeFake().run(["echo-stdin"], stdin: Data(#"{"n": 3}"#.utf8), as: Count.self)
        #expect(c == Count(n: 3))
    }

    /// Save in Review sends every change on stdin. A dewey that stops before reading it (a broken
    /// dewey.toml, an unplugged disk) closes the pipe under the write: that must be an error on the
    /// screen, not SIGPIPE ending the app.
    @Test func aDeweyThatExitsWithoutReadingItsInputIsAnErrorNotACrash() async throws {
        let big = Data(repeating: UInt8(ascii: "x"), count: 4_000_000)  // far more than a pipe holds
        await #expect(throws: DeweyError.failed(code: "config", message: "broken settings")) {
            try await makeFake().run(["deaf"], stdin: big, as: Value.self)
        }
    }

    @Test func errorEventThrowsWithItsCode() async throws {
        await #expect(throws: DeweyError.failed(code: "nothing_to_undo", message: "nothing to undo")) {
            try await makeFake().run(["fail"], as: Value.self)
        }
    }

    @Test func exitWithoutClosingEventIsACrashWithStderr() async throws {
        do {
            _ = try await makeFake().run(["crash"], as: Value.self)
            Issue.record("expected a crash")
        } catch DeweyError.crashed(let status, let stderr) {
            #expect(status == 3)
            #expect(stderr.contains("Traceback"))
        }
    }

    @Test func lotsOfStderrNeverBlocksTheRun() async throws {
        let v = try await makeFake().run(["noisy"], as: Value.self)  // ~150 KB: more than a pipe holds
        #expect(v.value == "survived")
    }

    @Test func cancelSendsSigintAndReportsTheBatch() async throws {
        let run = try makeFake().start(["slow"])
        var events: [DeweyEvent] = []
        for await e in run.events {
            events.append(e)
            if case .progress = e { run.cancel() }
        }
        #expect(events.last == .interrupted(batch: "b1", message: "stopped"))
        #expect(await run.exitStatus() == 130)
    }

    @Test func cancellingTheTaskCancelsDewey() async throws {
        let cli = try makeFake()
        let task = Task { try await cli.run(["slow"], as: Value.self) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: DeweyError.interrupted(batch: "b1")) { try await task.value }
    }

    /// A scan stuck on a disk that stopped answering never sees the SIGINT. Cancel still ends it.
    @Test func aDeweyThatDoesntHearCancelIsEnded() async throws {
        var cli = try makeFake()
        cli.patience = StopPatience(terminate: 0.2, kill: 0.5)
        let run = try cli.start(["stuck"])
        let started = Date()
        for await e in run.events {
            if case .progress = e { run.cancel() }
        }
        #expect(await run.exitStatus() == SIGKILL)
        #expect(Date().timeIntervalSince(started) < 5)

        let task = Task { try await cli.run(["stuck"], as: Value.self) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: DeweyError.crashed(status: SIGKILL, stderr: "")) { try await task.value }
    }

    /// A move is only asked to stop: ending it mid-copy would leave half a file behind.
    @Test func aMoveIsAskedToStopAndNeverEnded() async throws {
        var cli = try makeFake()
        cli.patience = StopPatience(terminate: 0.1, kill: 0.2)
        let run = try cli.start(["apply", "/some/root"])
        var last: DeweyEvent?
        for await e in run.events {
            if case .progress = e { run.cancel() }
            last = e
        }
        #expect(last?.isClosing == true)  // it got to finish what it was doing, a second later
        #expect(await run.exitStatus() == 0)
        #expect(DeweyRun.movesFiles(["undo", "/r", "--batch", "b"]))
        #expect(!DeweyRun.movesFiles(["apply", "/r", "--dry-run"]))
        #expect(!DeweyRun.movesFiles(["scan", "/r"]) && !DeweyRun.movesFiles(["plan", "/r"]))
    }

    @Test func missingExecutableIsALaunchError() async throws {
        let cli = DeweyCLI(executable: URL(fileURLWithPath: "/nonexistent/dewey"))
        await #expect {
            try await cli.run(["app-info"], as: AppInfo.self)
        } throws: { error in
            if case DeweyError.launch = error { true } else { false }
        }
    }
}

/// The dewey the README installs, for tests that run the real thing (skipped without it).
/// DEWEY_TEST_DEWEY picks another one: `make test-app` runs these against the app's own copy.
let realDewey: URL? = {
    let url = ProcessInfo.processInfo.environment["DEWEY_TEST_DEWEY"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".venvs/dewey/bin/dewey")
    return ToolLocator.isExecutable(url) ? url : nil
}()

@Suite(.timeLimit(.minutes(1)))
struct RealDeweyTests {
    @Test(.enabled(if: realDewey != nil, "needs ~/.venvs/dewey (see README)"))
    func appInfoSpeaksTheSupportedProtocol() async throws {
        let info = try await DeweyCLI(executable: realDewey!).appInfo()
        #expect(info.protocolVersion == AppInfo.supportedProtocol)
    }

    @Test(.enabled(if: realDewey != nil, "needs ~/.venvs/dewey (see README)"))
    func errorCodesComeThrough() async throws {
        await #expect(throws: DeweyError.failed(code: "not_a_folder", message: "not a folder: /nonexistent-dewey-root")) {
            try await DeweyCLI(executable: realDewey!).run(["status", "/nonexistent-dewey-root"], as: Value.self)
        }
    }
}
