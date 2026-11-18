import Foundation
import Testing
@testable import DeweyCore

/// Lines copied from real `dewey … --json` output (protocol 1).
struct EventsTests {
    @Test func parsesEveryEventKind() throws {
        #expect(DeweyEvent.parse(#"{"event": "log", "text": "Plan 1: 2 auto · 0 review"}"#) == .log("Plan 1: 2 auto · 0 review"))
        #expect(DeweyEvent.parse(#"{"event": "error", "code": "nothing_to_undo", "message": "nothing to undo"}"#)
                == .error(code: "nothing_to_undo", message: "nothing to undo"))
        #expect(DeweyEvent.parse(#"{"event": "interrupted", "batch": "20261117-201500-p1", "message": "saved"}"#)
                == .interrupted(batch: "20261117-201500-p1", message: "saved"))
        #expect(DeweyEvent.parse(#"{"event": "interrupted", "batch": null, "message": "saved"}"#)
                == .interrupted(batch: nil, message: "saved"))
        #expect(DeweyEvent.parse("Traceback (most recent call last):") == .unreadable("Traceback (most recent call last):"))
        #expect(DeweyEvent.parse(#"{"event": "something-new"}"#) == .unreadable(#"{"event": "something-new"}"#))
    }

    @Test func parsesProgress() throws {
        let line = #"{"event": "progress", "phase": "hash", "label": "Hashing", "unit": "files", "n": 1, "total": 3, "bytes": 11, "total_bytes": 22, "rate": 2922.2, "elapsed": 0.0, "eta": null, "extra": "", "done": false}"#
        guard case .progress(let p) = DeweyEvent.parse(line) else {
            Issue.record("not a progress event")
            return
        }
        #expect(p.phase == "hash")
        #expect(p.total == 3)
        #expect(p.totalBytes == 22)
        #expect(p.eta == nil)
        #expect(p.fraction == 0.5)  // by bytes, not by count (1 of 3)
        #expect(!p.done)
    }

    @Test func progressWithoutTotalHasNoFractionUntilDone() throws {
        let walking = #"{"event": "progress", "phase": "walk", "label": "Walking", "unit": "entries", "n": 3, "total": null, "bytes": 0, "total_bytes": null, "rate": 21454.16, "elapsed": 0.0, "eta": null, "extra": "", "done": false}"#
        guard case .progress(var p) = DeweyEvent.parse(walking) else {
            Issue.record("not a progress event")
            return
        }
        #expect(p.fraction == nil)
        p.done = true
        #expect(p.fraction == 1)
    }

    @Test func resultKeepsItsDataForTheCaller() throws {
        let line = #"{"event": "result", "data": {"version": "0.1.0", "protocol": 1, "python": "3.12.16", "executable": "/Users/x/.venvs/dewey/bin/python"}}"#
        let event = DeweyEvent.parse(line)
        #expect(event.isClosing)
        guard case .result(let data) = event else {
            Issue.record("not a result")
            return
        }
        let info = try DeweyEvent.decoder().decode(AppInfo.self, from: data)
        #expect(info == AppInfo(version: "0.1.0", protocolVersion: 1, python: "3.12.16",
                                executable: "/Users/x/.venvs/dewey/bin/python"))
    }

    @Test func onlyResultErrorAndInterruptedClose() {
        #expect(!DeweyEvent.log("x").isClosing)
        #expect(!DeweyEvent.unreadable("x").isClosing)
        #expect(DeweyEvent.error(code: "e", message: "m").isClosing)
        #expect(DeweyEvent.interrupted(batch: nil, message: "").isClosing)
    }
}
