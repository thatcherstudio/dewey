import Foundation

/// Reads a child process's pipe on a dispatch queue (`readabilityHandler`), never on Swift's
/// cooperative thread pool. `FileHandle.bytes` does blocking reads there, and a few processes running
/// at once (dewey's stdout + stderr, laya-serve's log) were enough to starve the pool: nothing drained
/// the pipes and the children blocked on write.
///
/// The pipe is always drained to the end, even if nobody is listening any more, so a child can never
/// block on a full pipe.
enum PipeReader {
    /// Complete lines (without the newline) until EOF.
    static func lines(_ handle: FileHandle) -> AsyncStream<String> {
        let (stream, cont) = AsyncStream<String>.makeStream()
        let buffer = LineBuffer()
        handle.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty {  // EOF
                h.readabilityHandler = nil
                if let rest = buffer.finish() { cont.yield(rest) }
                cont.finish()
                return
            }
            for line in buffer.append(chunk) { cont.yield(line) }
        }
        return stream
    }

    /// Everything until EOF, keeping the last `keepLast` bytes.
    static func tail(_ handle: FileHandle, keepLast: Int) -> Task<String, Never> {
        let (stream, cont) = AsyncStream<Data>.makeStream()
        handle.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty {
                h.readabilityHandler = nil
                cont.finish()
            } else {
                cont.yield(chunk)
            }
        }
        return Task {
            var tail = Data()
            for await chunk in stream {
                tail.append(chunk)
                if tail.count > 2 * keepLast { tail = Data(tail.suffix(keepLast)) }
            }
            return String(decoding: tail.suffix(keepLast), as: UTF8.self)
        }
    }

    /// Write `data` and close, off the cooperative pool (a big write blocks until the child reads it).
    ///
    /// A child that exits before reading it all (dewey stopping on a broken dewey.toml) closes the pipe
    /// under the write. By default that is SIGPIPE, which ends the whole app; F_SETNOSIGPIPE makes it
    /// an error on this one write instead, and the child's own error event says what went wrong.
    static func write(_ data: Data?, to handle: FileHandle) {
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        DispatchQueue.global(qos: .userInitiated).async {
            if let data { try? handle.write(contentsOf: data) }
            try? handle.close()
        }
    }
}

/// What a child has written so far, without waiting for the pipe to close.
///
/// `lines` and `tail` read to the end of the pipe, and the end comes only when every process that
/// holds its other side has exited. A shell profile that leaves something running (`ssh-agent`,
/// anything with `&`) hands that process the pipe, so the end doesn't come while it lives. This one
/// reads on a queue of its own until `finish()`, which takes what is in the pipe by then and stops.
final class PipeCollector: @unchecked Sendable {  // `data` is only touched on `queue`
    private let handle: FileHandle
    private let keepLast: Int
    private let queue = DispatchQueue(label: "dewey.pipe-collector")
    private let source: DispatchSourceRead
    private var data = Data()

    init(_ handle: FileHandle, keepLast: Int) {
        self.handle = handle
        self.keepLast = keepLast
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)  // a read takes what is there and returns
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { [handle] in _ = handle }  // the descriptor stays open until the source lets go
        source.resume()
    }

    deinit { source.cancel() }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let n = read(handle.fileDescriptor, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return }  // 0: the pipe closed. -1: nothing more in it for now.
            data.append(contentsOf: buffer[0..<n])
            if data.count > 2 * keepLast { data = Data(data.suffix(keepLast)) }
        }
    }

    /// The last `keepLast` bytes written up to now. Nothing is read after this.
    func finish() -> String {
        queue.sync {
            drain()
            source.cancel()
            return String(decoding: data.suffix(keepLast), as: UTF8.self)
        }
    }
}

/// Splits chunks into lines. Only touched from one handle's readability queue, which is serial.
final class LineBuffer: @unchecked Sendable {
    private var pending = Data()

    func append(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        var start = pending.startIndex
        while let nl = pending[start...].firstIndex(of: 0x0A) {
            lines.append(String(decoding: pending[start..<nl], as: UTF8.self))
            start = pending.index(after: nl)
        }
        if start != pending.startIndex { pending = Data(pending[start...]) }
        return lines
    }

    func finish() -> String? {
        defer { pending = Data() }
        return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
    }
}
