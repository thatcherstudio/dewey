import Foundation
import Observation

/// A process as the system knows it now: enough to tell it from another one that got the same pid.
struct RunningProcess: Equatable, Sendable {
    var startSec: Int
    var startUsec: Int
    var parent: Int32

    /// nil when no process has this pid (or it has exited and only waits to be collected).
    static func find(_ pid: Int32) -> RunningProcess? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard pid > 0, sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0,
              info.kp_proc.p_pid == pid, info.kp_proc.p_stat != UInt8(SZOMB) else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        return RunningProcess(startSec: Int(started.tv_sec), startUsec: Int(started.tv_usec), parent: info.kp_eproc.e_ppid)
    }
}

/// The laya-serve a Dewey started, written down so the next launch can find it if this one never
/// gets to stop it (a crash, Force Quit, the Mac's power). The start time makes the pid unmistakable.
struct ServerRecord: Codable, Equatable, Sendable {
    var pid: Int32
    var startSec: Int
    var startUsec: Int
    var port: Int
}

/// Starts and stops `laya-serve`, the local decision model, and watches its `/health`.
///
/// laya-serve loads the model before it starts listening, so "connection refused" while our process
/// runs means "still loading". A server that was already running on the port is used as is and never
/// stopped by the app, because the app didn't start it. The one exception is a server an earlier
/// Dewey started and left behind: `stopLeftover()` ends that one at launch.
///
/// The server is started on this Mac, on the port of `baseURL`, so it is started only when
/// `baseURL` names this Mac. A Laya on another machine is watched, never started.
@MainActor @Observable
public final class LayaController {
    public struct Health: Equatable, Sendable {
        public var loaded: [String]
        public var device: String?
    }

    public enum Status: Equatable, Sendable {
        case unknown
        case stopped
        case starting(since: Date)
        case ready(Health)
        case failed(String)
    }

    public enum Probe: Equatable, Sendable {
        case ok(Health)
        case refused
        case other(String)
    }

    public private(set) var status: Status = .unknown
    /// True only for a laya-serve this app started (and will stop on quit).
    public private(set) var ownsServer = false
    /// The last 200 lines laya-serve printed.
    public private(set) var log: [String] = []
    /// The laya-serve this app is running, while it runs.
    public private(set) var executable: URL?
    /// Where Laya is. An address on this Mac that gives no port ("http://localhost") means
    /// laya-serve's own, 8000, and reads back with it: the server is started on that port and looked
    /// for on that port. (0.2.1 started it on 8000 and then asked port 80, with no end.)
    public var baseURL: URL {
        get { address }
        set { address = Self.withPort(newValue) }
    }
    public var model: String

    private var address: URL
    private var process: Process?
    private var stopping = false
    private var pollTask: Task<Void, Never>?
    private var starting: Task<Void, Never>?
    private var leftoverNote: String?
    /// Where the running server is written down (`ServerRecord`); nil keeps no record.
    @ObservationIgnored private let record: URL?
    /// Seconds a laya-serve this app started may load before "starting" becomes a failure with a reason.
    @ObservationIgnored private let startupLimit: TimeInterval

    /// The port laya-serve listens on when it isn't told another.
    public static let defaultPort = 8000

    public init(baseURL: URL = URL(string: "http://127.0.0.1:8000")!, model: String = "english", record: URL? = nil,
                startupLimit: TimeInterval = 600) {
        self.address = Self.withPort(baseURL)
        self.model = model
        self.record = record
        self.startupLimit = startupLimit
    }

    public var isRunning: Bool { process != nil }

    public var port: Int { baseURL.port ?? Self.defaultPort }

    /// `baseURL` names this Mac, so this app can start the server it names.
    public var isLocal: Bool { ThisMac.isNamed(by: baseURL.host(percentEncoded: false) ?? "") }

    static func withPort(_ url: URL) -> URL {
        guard url.port == nil, ThisMac.isNamed(by: url.host(percentEncoded: false) ?? ""),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.port = defaultPort
        return parts.url ?? url
    }

    /// Look at the port without starting anything.
    public func refresh() async {
        guard process == nil else { return }
        let probe = await Self.probe(baseURL)
        switch probe {
        case .ok(let h): status = .ready(h)
        case _ where !isLocal: status = .failed(elsewhere(probe))
        case .refused: status = .stopped
        case .other(let why): status = .failed(portTaken(why))
        }
    }

    /// Start laya-serve, unless one already answers. Returns once it is launched (status `.starting`)
    /// or known not to be. A second call while the first is still on its way waits for that one:
    /// two of them side by side each found nothing running and each started a server.
    public func start(executable: URL) async {
        if let starting { return await starting.value }
        let task = Task { await self.launch(executable) }
        starting = task
        await task.value
        starting = nil
    }

    private func launch(_ executable: URL) async {
        guard process == nil else { return }
        let probe = await Self.probe(baseURL)
        if case .ok(let h) = probe {
            status = .ready(h)  // already running (a terminal tab, an earlier launch): use it, don't own it
            return
        }
        guard isLocal else {
            // Another machine. A server started here would listen on this Mac, where nothing asks:
            // 0.2.1 started one anyway, loaded the model, and waited for the other address for good.
            status = .failed(elsewhere(probe))
            return
        }
        if case .other(let why) = probe {
            status = .failed(portTaken(why))
            return
        }
        let p = Process()
        p.executableURL = executable
        var env = ProcessInfo.processInfo.environment
        env["LAYA_HOST"] = "127.0.0.1"  // without it laya-serve listens on the whole network
        env["LAYA_PORT"] = String(port)
        env["LAYA_MODELS"] = model      // without it laya-serve loads all three checkpoints
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus, pid = proc.processIdentifier
            Task { @MainActor in self?.exited(code, pid: pid) }
        }
        do {
            try p.run()
        } catch {
            status = .failed("Couldn't start \(executable.path): \(error.localizedDescription)")
            return
        }
        process = p
        remember(p.processIdentifier)
        self.executable = executable
        ownsServer = true
        stopping = false
        log = leftoverNote.map { [$0] } ?? []  // said once, at the top of the next server's log
        leftoverNote = nil
        status = .starting(since: .now)
        let lines = PipeReader.lines(pipe.fileHandleForReading)
        Task { [weak self] in
            for await line in lines { self?.append(line) }
        }
        pollTask = Task { [weak self] in await self?.pollUntilReady() }
    }

    /// SIGTERM (uvicorn shuts down cleanly), then SIGKILL if it is still there after 5 s.
    public func stop() {
        guard let p = process, p.isRunning else { return }
        stopping = true
        p.terminate()
        let pid = p.processIdentifier
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if self?.process?.processIdentifier == pid { kill(pid, SIGKILL) }
        }
    }

    /// `stop()`, then wait for it to exit: about 5 s at most, when SIGKILL ends it.
    public func stopAndWait() async {
        stop()
        let deadline = Date().addingTimeInterval(7)
        while process != nil && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
    }

    /// App quit: stop the server this app started and wait up to 3 s, so it never outlives the app.
    public func stopForQuit() {
        guard let p = process, p.isRunning else { return }
        stopping = true
        p.terminate()
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        forget(p.processIdentifier)
    }

    // MARK: - a server left behind

    /// At launch: end the laya-serve an earlier Dewey started and never got to stop. Without this the
    /// next start would find it answering, take it for someone else's and leave it running for good,
    /// with nobody reading its log.
    ///
    /// It is ended only when it is that very process (same pid and start time as written down) and its
    /// Dewey is gone (it now belongs to launchd): a server another running Dewey owns is left alone.
    @discardableResult
    public func stopLeftover() async -> Bool {
        guard process == nil, let record, let was = Self.read(record) else { return false }
        /// The process written down, while it is still there.
        func same() -> RunningProcess? {
            guard let now = RunningProcess.find(was.pid), now.startSec == was.startSec,
                  now.startUsec == was.startUsec else { return nil }
            return now
        }
        guard let now = same() else {  // gone, or the pid is another program's now: the note is out of date
            try? FileManager.default.removeItem(at: record)
            return false
        }
        guard now.parent == 1 else { return false }  // the child of a Dewey that is running: theirs, note and all
        kill(was.pid, SIGTERM)
        for patience in [5.0, 2.0] {  // uvicorn shuts down cleanly; SIGKILL if it hasn't after 5 s
            let deadline = Date().addingTimeInterval(patience)
            while same() != nil && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            if same() != nil { kill(was.pid, SIGKILL) }
        }
        try? FileManager.default.removeItem(at: record)
        let note = "Stopped the laya-serve an earlier Dewey left running (pid \(was.pid), port \(was.port))."
        leftoverNote = note
        append(note)
        return true
    }

    private func remember(_ pid: Int32) {
        guard let record, let now = RunningProcess.find(pid) else { return }
        let note = ServerRecord(pid: pid, startSec: now.startSec, startUsec: now.startUsec, port: port)
        try? FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(note).write(to: record, options: .atomic)
    }

    /// Drop the note once the server it names is gone (not one a newer start has written since).
    private func forget(_ pid: Int32) {
        guard let record, Self.read(record)?.pid == pid else { return }
        try? FileManager.default.removeItem(at: record)
    }

    static func read(_ record: URL) -> ServerRecord? {
        (try? Data(contentsOf: record)).flatMap { try? JSONDecoder().decode(ServerRecord.self, from: $0) }
    }

    /// Ask `/health` once a second until the server answers. After `startupLimit` without an answer,
    /// "starting" becomes a failure that says so, instead of a spinner with no end. The server isn't
    /// stopped and the asking goes on: a first start that downloads the model can take longer, and
    /// then turns ready by itself.
    private func pollUntilReady() async {
        let began = Date()
        var saidSo = false
        while !Task.isCancelled, process != nil {
            if case .ok(let h) = await Self.probe(baseURL) {
                if process != nil { status = .ready(h) }
                return
            }
            if !saidSo, process != nil, Date().timeIntervalSince(began) >= startupLimit {
                saidSo = true
                status = .failed(Self.stillLoading(after: startupLimit, at: baseURL))
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    static func stillLoading(after seconds: TimeInterval, at url: URL) -> String {
        let minutes = Int((seconds / 60).rounded())
        let waited = minutes >= 1 ? "\(minutes) \(minutes == 1 ? "minute" : "minutes")" : "\(Int(seconds)) seconds"
        return "laya-serve has been running for \(waited) and still doesn't answer at \(url.absoluteString). "
            + "Its log may say why. Dewey keeps asking; Stop ends it."
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    private func exited(_ code: Int32, pid: Int32) {
        pollTask?.cancel()
        forget(pid)
        process = nil
        executable = nil
        ownsServer = false
        if stopping {
            status = .stopped
        } else {
            let last = log.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "no output"
            status = .failed("laya-serve stopped (exit \(code)): \(last)")
        }
        stopping = false
    }

    private func portTaken(_ why: String) -> String {
        "Port \(port) answers, but not like laya-serve (\(why)). Stop whatever uses it, or change the Laya URL in Settings."
    }

    /// The Laya URL names another machine, and nothing there answers like laya-serve.
    private func elsewhere(_ probe: Probe) -> String {
        var why = ""
        if case .other(let said) = probe { why = " (\(said))" }
        return "Laya at \(ModelSource.place(baseURL.absoluteString)) isn't answering\(why). That address isn't this Mac, "
            + "so Dewey can't start Laya there. Start it on that machine, or change the Laya URL in Dewey > Settings."
    }

    // MARK: - health

    public nonisolated static func probe(_ base: URL) async -> Probe {
        var req = URLRequest(url: base.appending(path: "health"))
        req.timeoutInterval = 2
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            return interpret(data: data, statusCode: (resp as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let e as URLError where e.code == .cannotConnectToHost || e.code == .cannotFindHost {
            return .refused
        } catch {
            return .other(error.localizedDescription)
        }
    }

    /// `/health` is `{"status": "ok", "loaded": [...], "device": "mps", ...}` once the model is in memory.
    public nonisolated static func interpret(data: Data, statusCode: Int) -> Probe {
        guard statusCode == 200 else { return .other("HTTP \(statusCode)") }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["status"] as? String == "ok" else {
            return .other("no \"status\": \"ok\" in /health")
        }
        return .ok(Health(loaded: obj["loaded"] as? [String] ?? [], device: obj["device"] as? String))
    }
}
