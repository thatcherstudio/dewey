import Foundation
import Testing
@testable import DeweyCore

struct LineBufferTests {
    /// The same bytes give the same lines however the pipe cuts them up.
    @Test func linesDontDependOnWhereTheChunksEnd() {
        let text = "one\n\ntwo é 日本\nthree\n\n\nfour"
        let bytes = Data(text.utf8)
        for size in 1...bytes.count {
            let buffer = LineBuffer()
            var lines: [String] = []
            var at = 0
            while at < bytes.count {
                // a slice, as `availableData` never is, so its indices don't start at 0
                lines += buffer.append(bytes[at..<min(at + size, bytes.count)])
                at += size
            }
            #expect(lines == ["one", "", "two é 日本", "three", "", ""], "in chunks of \(size)")
            #expect(buffer.finish() == "four", "in chunks of \(size)")
            #expect(buffer.finish() == nil)
        }
    }

    @Test func aLastLineWithItsNewlineLeavesNothingBehind() {
        let buffer = LineBuffer()
        #expect(buffer.append(Data("a\nb\n".utf8)) == ["a", "b"])
        #expect(buffer.finish() == nil)
        #expect(buffer.append(Data()) == [])
        #expect(buffer.finish() == nil)
    }

    /// `dewey rows --json` is one line for the whole plan, megabytes long for a big one, and the pipe
    /// hands it over a piece at a time. 0.2.1 looked through everything read so far for each piece:
    /// these 4 MB in 1 KB pieces cost it about a minute of processor time. Searched once, they cost
    /// a few hundredths of a second.
    ///
    /// Processor time of this thread, not time on the clock: the tests run side by side, and on a
    /// busy machine (GitHub's) the clock says more about the other tests than about this one.
    @Test(.timeLimit(.minutes(2))) func aVeryLongLineIsSearchedOnce() {
        let chunk = Data(repeating: UInt8(ascii: "x"), count: 1_024)
        let buffer = LineBuffer()
        let started = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        var early = 0
        for _ in 0..<4_000 { early += buffer.append(chunk).count }
        let lines = buffer.append(Data("end\nnext".utf8))
        let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - started) / 1e9
        #expect(early == 0)
        #expect(lines.count == 1)
        #expect(lines.first?.utf8.count == 4_000 * 1_024 + 3)
        #expect(lines.first?.hasSuffix("xend") == true)
        #expect(buffer.finish() == "next")
        #expect(cpu < 5, "took \(cpu) s of processor time")
    }

    /// A long line through a real pipe, in pieces of whatever size the pipe gives.
    @Test(.timeLimit(.minutes(1))) func aVeryLongLineFromAProcessArrivesWhole() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "dewey-line-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        var text = Data(repeating: UInt8(ascii: "x"), count: 8_000_000)
        text.append(Data("\nlast".utf8))
        try text.write(to: file)
        let cat = Process()
        cat.executableURL = URL(fileURLWithPath: "/bin/cat")
        cat.arguments = [file.path]
        let out = Pipe()
        cat.standardOutput = out
        let lines = PipeReader.lines(out.fileHandleForReading)
        try cat.run()
        var lengths: [Int] = []
        for await line in lines { lengths.append(line.utf8.count) }
        #expect(lengths == [8_000_000, 4])
    }
}
