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
    static func write(_ data: Data?, to handle: FileHandle) {
        DispatchQueue.global(qos: .userInitiated).async {
            if let data { try? handle.write(contentsOf: data) }
            try? handle.close()
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
