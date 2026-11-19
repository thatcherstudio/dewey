import Foundation

public enum DeweyError: Error, Equatable, LocalizedError {
    /// dewey reported an error event. `code` is machine-readable (see src/dewey/errors.py).
    case failed(code: String, message: String)
    /// Stopped by Cancel (SIGINT). `batch` is set when files were moving: undo that batch.
    case interrupted(batch: String?)
    /// Exited without a closing event (a Python crash before dewey started, a wrong executable, a
    /// stuck dewey ended after Cancel…).
    case crashed(status: Int32, stderr: String)
    case launch(String)
    case undecodable(String)

    public var errorDescription: String? {
        switch self {
        case .failed(_, let message): message
        case .interrupted: "Stopped. Finished work is saved."
        case .crashed(let status, let stderr):
            "dewey exited with status \(status) without saying why."
                + (stderr.isEmpty ? "" : "\n" + stderr.split(separator: "\n").suffix(6).joined(separator: "\n"))
        case .launch(let why): "Couldn't start dewey: \(why)"
        case .undecodable(let why): "dewey answered in a form this app doesn't understand: \(why)"
        }
    }
}

/// How long a cancelled dewey gets to stop by itself before it is made to.
public struct StopPatience: Sendable, Equatable {
    /// Seconds after SIGINT before SIGTERM.
    public var terminate: TimeInterval
    /// Seconds after SIGINT before SIGKILL.
    public var kill: TimeInterval

    public init(terminate: TimeInterval = 5, kill: TimeInterval = 8) {
        self.terminate = terminate
        self.kill = kill
    }
}

/// One running `dewey <command> --json` process.
public final class DeweyRun: @unchecked Sendable {  // Process isn't Sendable; it is only used thread-safely here
    public let arguments: [String]
    /// Every event, in order. Ends when dewey closes stdout (it exits right after).
    public let events: AsyncStream<DeweyEvent>
    private let process: Process
    private let exitTask: Task<Int32, Never>
    private let stderrTask: Task<String, Never>
    private let patience: StopPatience
    private let lock = NSLock()
    private var cancelled = false

    init(arguments: [String], events: AsyncStream<DeweyEvent>, process: Process,
         exitTask: Task<Int32, Never>, stderrTask: Task<String, Never>, patience: StopPatience) {
        self.arguments = arguments
        self.events = events
        self.process = process
        self.exitTask = exitTask
        self.stderrTask = stderrTask
        self.patience = patience
    }

    /// A move or an undo. It is only ever asked to stop (SIGINT, after the file in hand): ending it
    /// in the middle of a copy to another disk would leave a half-written file behind.
    public static func movesFiles(_ arguments: [String]) -> Bool {
        switch arguments.first {
        case "undo": true
        case "apply": !arguments.contains("--dry-run")
        default: false
        }
    }

    /// Cancel the way Ctrl-C does: dewey stops after the current item, keeps what's done, and a batch
    /// that was moving files stays undoable.
    ///
    /// A dewey that moves nothing (scan, plan and the rest) and is still there after that is stuck, on
    /// a disk that stopped answering for one: it gets SIGTERM, then SIGKILL. Nothing is left half done
    /// by that: its catalog is SQLite, a plan counts only once the catalog has it, and the files it
    /// saves (the plan CSV, dewey.toml) are swapped in whole.
    public func cancel() {
        guard process.isRunning else { return }
        process.interrupt()
        guard !Self.movesFiles(arguments) else { return }
        lock.lock()
        let first = !cancelled
        cancelled = true
        lock.unlock()
        guard first else { return }
        let queue = DispatchQueue.global(qos: .userInitiated)
        queue.asyncAfter(deadline: .now() + patience.terminate) { [process] in
            if process.isRunning { process.terminate() }
        }
        queue.asyncAfter(deadline: .now() + patience.kill) { [process] in
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    public func exitStatus() async -> Int32 { await exitTask.value }
    /// The last 64 KB of stderr (tracebacks only; events never go there).
    public func stderr() async -> String { await stderrTask.value }
}

/// Runs the dewey command-line tool. One short process per action; dewey owns every file format.
public struct DeweyCLI: Sendable {
    public let executable: URL
    public var environment: [String: String]
    public var patience = StopPatience()

    public init(executable: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.executable = executable
        self.environment = environment
    }

    /// Start `dewey ARGS --json`. `stdin` is written and closed (dewey never reads the app's own stdin).
    public func start(_ arguments: [String], stdin: Data? = nil) throws -> DeweyRun {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments + ["--json"]
        var env = environment
        env["PYTHONIOENCODING"] = "utf-8"  // tracebacks on stderr; the events themselves are ASCII
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env
        let out = Pipe(), err = Pipe(), input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input

        let (exitStream, exitCont) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { p in
            exitCont.yield(p.terminationStatus)
            exitCont.finish()
        }
        do {
            try process.run()
        } catch {
            throw DeweyError.launch("\(executable.path): \(error.localizedDescription)")
        }

        PipeReader.write(stdin, to: input.fileHandleForWriting)
        let lines = PipeReader.lines(out.fileHandleForReading)
        let events = AsyncStream<DeweyEvent> { cont in
            let task = Task {
                for await line in lines where !line.isEmpty { cont.yield(DeweyEvent.parse(line)) }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
        let stderrTask = PipeReader.tail(err.fileHandleForReading, keepLast: 65_536)  // always drained
        let exitTask = Task { () -> Int32 in
            for await status in exitStream { return status }
            return -1
        }
        return DeweyRun(arguments: arguments, events: events, process: process, exitTask: exitTask,
                        stderrTask: stderrTask, patience: patience)
    }

    /// Run to the end, passing every event to `onEvent`, and decode the result. Cancelling the calling
    /// task cancels dewey (`DeweyRun.cancel`), which then throws `.interrupted`, or `.crashed` when
    /// dewey had to be ended.
    public func run<T: Decodable & Sendable>(
        _ arguments: [String], stdin: Data? = nil, as type: T.Type,
        onEvent: @escaping @Sendable (DeweyEvent) async -> Void = { _ in }
    ) async throws -> T {
        let run = try start(arguments, stdin: stdin)
        // Read the events in a task of their own: a cancelled caller's `for await` would stop at once
        // and miss the `interrupted` event dewey sends on its way out.
        let reader = Task { () -> DeweyEvent? in
            var closing: DeweyEvent?
            for await event in run.events {
                if event.isClosing { closing = event }
                await onEvent(event)
            }
            return closing
        }
        return try await withTaskCancellationHandler {
            let closing = await reader.value
            let status = await run.exitStatus()
            switch closing {
            case .result(let data):
                do {
                    return try DeweyEvent.decoder().decode(T.self, from: data)
                } catch {
                    throw DeweyError.undecodable("\(arguments.first ?? "?"): \(error)")
                }
            case .error(let code, let message):
                throw DeweyError.failed(code: code, message: message)
            case .interrupted(let batch, _):
                throw DeweyError.interrupted(batch: batch)
            default:
                throw DeweyError.crashed(status: status, stderr: await run.stderr())
            }
        } onCancel: {
            run.cancel()
        }
    }

    public func appInfo() async throws -> AppInfo {
        try await run(["app-info"], as: AppInfo.self)
    }
}
