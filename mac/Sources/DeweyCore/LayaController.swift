import Foundation
import Observation

/// Starts and stops `laya-serve`, the local decision model, and watches its `/health`.
///
/// laya-serve loads the model before it starts listening, so "connection refused" while our process
/// runs means "still loading". A server that was already running on the port is used as is and never
/// stopped by the app, because the app didn't start it.
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
    public var baseURL: URL
    public var model: String

    private var process: Process?
    private var stopping = false
    private var pollTask: Task<Void, Never>?

    public init(baseURL: URL = URL(string: "http://127.0.0.1:8000")!, model: String = "english") {
        self.baseURL = baseURL
        self.model = model
    }

    public var isRunning: Bool { process != nil }

    public var port: Int { baseURL.port ?? 8000 }

    /// Look at the port without starting anything.
    public func refresh() async {
        guard process == nil else { return }
        switch await Self.probe(baseURL) {
        case .ok(let h): status = .ready(h)
        case .refused: status = .stopped
        case .other(let why): status = .failed(portTaken(why))
        }
    }

    public func start(executable: URL) async {
        guard process == nil else { return }
        switch await Self.probe(baseURL) {
        case .ok(let h):
            status = .ready(h)  // already running (a terminal tab, an earlier launch): use it, don't own it
            return
        case .other(let why):
            status = .failed(portTaken(why))
            return
        case .refused:
            break
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
            let code = proc.terminationStatus
            Task { @MainActor in self?.exited(code) }
        }
        do {
            try p.run()
        } catch {
            status = .failed("Couldn't start \(executable.path): \(error.localizedDescription)")
            return
        }
        process = p
        ownsServer = true
        stopping = false
        log = []
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

    /// App quit: stop the server this app started and wait up to 3 s, so it never outlives the app.
    public func stopForQuit() {
        guard let p = process, p.isRunning else { return }
        stopping = true
        p.terminate()
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }

    private func pollUntilReady() async {
        while !Task.isCancelled, process != nil {
            if case .ok(let h) = await Self.probe(baseURL) {
                if process != nil { status = .ready(h) }
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    private func exited(_ code: Int32) {
        pollTask?.cancel()
        process = nil
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
