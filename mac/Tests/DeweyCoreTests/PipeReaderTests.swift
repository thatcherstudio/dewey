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
    /// these 32 MB in 16 KB pieces took it 226 s. Searched once, they take 0.2 s.
    @Test(.timeLimit(.minutes(1))) func aVeryLongLineIsSearchedOnce() {
        let chunk = Data(repeating: UInt8(ascii: "x"), count: 16_384)
        let buffer = LineBuffer()
        let started = Date()
        for _ in 0..<2_000 { #expect(buffer.append(chunk).isEmpty) }
        let lines = buffer.append(Data("end\nnext".utf8))
        let took = Date().timeIntervalSince(started)
        #expect(lines.count == 1)
        #expect(lines.first?.utf8.count == 2_000 * 16_384 + 3)
        #expect(lines.first?.hasSuffix("xend") == true)
        #expect(buffer.finish() == "next")
        #expect(took < 10, "took \(took) s")
    }

    /// The same through a real pipe, in pieces of whatever size the pipe gives.
    @Test(.timeLimit(.minutes(1))) func aVeryLongLineFromAProcessArrivesWhole() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "dewey-line-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        var text = Data(repeating: UInt8(ascii: "x"), count: 32_000_000)
        text.append(Data("\nlast".utf8))
        try text.write(to: file)
        let cat = Process()
        cat.executableURL = URL(fileURLWithPath: "/bin/cat")
        cat.arguments = [file.path]
        let out = Pipe()
        cat.standardOutput = out
        let lines = PipeReader.lines(out.fileHandleForReading)
        let started = Date()
        try cat.run()
        var lengths: [Int] = []
        for await line in lines { lengths.append(line.utf8.count) }
        let took = Date().timeIntervalSince(started)
        #expect(lengths == [32_000_000, 4])
        #expect(took < 10, "took \(took) s")
    }
}
