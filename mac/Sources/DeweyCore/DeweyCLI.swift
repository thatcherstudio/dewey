import Foundation

public enum DeweyError: Error, Equatable, LocalizedError {
    /// dewey reported an error event. `code` is machine-readable (see src/dewey/errors.py).
    case failed(code: String, message: String)
    /// Stopped by Cancel (SIGINT). `batch` is set when files were moving: undo that batch.
    case interrupted(batch: String?)
    /// Exited without a closing event (a Python crash before dewey started, a wrong executable…).
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

/// One running `dewey <command> --json` process.
public final class DeweyRun: @unchecked Sendable {  // Process isn't Sendable; it is only used thread-safely here
    public let arguments: [String]
    /// Every event, in order. Ends when dewey closes stdout (it exits right after).
    public let events: AsyncStream<DeweyEvent>
    private let process: Process
    private let exitTask: Task<Int32, Never>
    private let stderrTask: Task<String, Never>

    init(arguments: [String], events: AsyncStream<DeweyEvent>, process: Process,
         exitTask: Task<Int32, Never>, stderrTask: Task<String, Never>) {
        self.arguments = arguments
        self.events = events
        self.process = process
        self.exitTask = exitTask
        self.stderrTask = stderrTask
    }

    /// Cancel the way Ctrl-C does: dewey stops after the current item, keeps what's done, and a batch
    /// that was moving files stays undoable.
    public func cancel() {
        if process.isRunning { process.interrupt() }
    }

    public func exitStatus() async -> Int32 { await exitTask.value }
    /// The last 64 KB of stderr (tracebacks only; events never go there).
    public func stderr() async -> String { await stderrTask.value }
}

/// Runs the dewey command-line tool. One short process per action; dewey owns every file format.
public struct DeweyCLI: Sendable {
    public let executable: URL
    public var environment: [String: String]

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
                        stderrTask: stderrTask)
    }

    /// Run to the end, passing every event to `onEvent`, and decode the result. Cancelling the calling
    /// task cancels dewey (SIGINT), which then throws `.interrupted`.
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
