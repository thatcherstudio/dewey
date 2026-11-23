import Foundation
import Testing
@testable import DeweyCore

private func tempFolder() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "dewey-settings-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Suite struct SettingsJSONTests {
    @Test func savesSnakeCaseAndLeavesOutWhatIsntSet() throws {
        var rule = FolderConfig.Rule(name: "pdfs", target: "PDFs")
        rule.ext = [".pdf"]
        rule.hasCamera = false
        let s = FolderConfig(
            plan: .init(dest: "", reviewDir: "_Review", keepDuplicate: "oldest", autoConfidence: 0.9,
                        reviewConfidence: 0.5, maxDepth: 0),
            decider: .init(backend: "none", url: "", model: "", trustChatConfidence: false),
            folders: .init(move: true, kinds: [.init(kind: "code", path: "Code", label: "code project")]),
            rules: [rule],
            categories: [.init(key: "  money ", path: "Money", desc: "bills")])
        let obj = try #require(try JSONSerialization.jsonObject(with: s.json()) as? [String: Any])
        let plan = try #require(obj["plan"] as? [String: Any])
        #expect(plan["auto_confidence"] as? Double == 0.9 && plan["keep_duplicate"] as? String == "oldest")
        let r = try #require((obj["rules"] as? [[String: Any]])?.first)
        #expect(Set(r.keys) == ["name", "target", "ext", "has_camera"])
        let c = try #require((obj["categories"] as? [[String: Any]])?.first)
        #expect(c["key"] as? String == "money", "names are trimmed")
        #expect(c["id"] == nil)
        #expect((obj["decider"] as? [String: Any])?["trust_chat_confidence"] as? Bool == false)
    }

    @Test func listsWhatNeedsFixing() throws {
        var s = FolderConfig(
            plan: .init(dest: "", reviewDir: "_Review", keepDuplicate: "oldest", autoConfidence: 0.6,
                        reviewConfidence: 0.7, maxDepth: 0),
            decider: .init(backend: "systemone", url: "", model: "", trustChatConfidence: false),
            folders: .init(move: true, kinds: []),
            rules: [.init(name: "x", target: "")],
            categories: [.init(key: "a"), .init(key: "a "), .init(key: "")])
        #expect(s.problems == ["The Review threshold has to be at or below the Move threshold.",
                               "Every folder needs a name.", "Two folders are called “a”.",
                               "Rule 1 (x) needs a name and a destination."])
        s.plan.reviewConfidence = 0.5
        s.rules = []
        s.categories = [.init(key: "only")]
        #expect(s.problems == ["The model needs at least 2 folders to choose from."])
        s.decider.backend = "none"
        #expect(s.problems.isEmpty)
    }

    @Test func changesHoldOnlyWhatChanged() throws {
        let base = FolderConfig(
            plan: .init(dest: "", reviewDir: "_Review", keepDuplicate: "oldest", autoConfidence: 0.85,
                        reviewConfidence: 0.5, maxDepth: 0),
            decider: .init(backend: "systemone", url: "u", model: "m", trustChatConfidence: false),
            folders: .init(move: true, kinds: [.init(kind: "code", path: "Code"), .init(kind: "cad", path: "CAD")]),
            rules: [.init(name: "a", target: "A")],
            categories: [.init(key: "x"), .init(key: "y")])
        var s = base
        #expect(String(decoding: try s.changes(from: base), as: UTF8.self) == "{}")
        s.plan.maxDepth = 1
        s.folders.kinds[1].path = "3D"
        s.categories.swapAt(0, 1)
        let obj = try #require(try JSONSerialization.jsonObject(with: s.changes(from: base)) as? [String: Any])
        #expect(Set(obj.keys) == ["plan", "folders", "categories"])
        #expect((obj["plan"] as? [String: Any])?.keys.sorted() == ["max_depth"])
        #expect((obj["folders"] as? [String: Any])?["kinds"] as? [[String: String]] == [["kind": "cad", "path": "3D"]])
        #expect((obj["categories"] as? [[String: Any]])?.map { $0["key"] as? String } == ["y", "x"])
    }

    @Test func listIdentityIsntPartOfEquality() {
        #expect(FolderConfig.Category(key: "a") == FolderConfig.Category(key: "a"))
        #expect(FolderConfig.Rule(name: "a", target: "A") == FolderConfig.Rule(name: "a", target: "A"))
    }
}

/// The ids the lists use (which rule is selected, which field has the cursor) across a new read of
/// the settings, where every item starts with an id of its own (0.2.2, group C).
@Suite struct SettingsIDTests {
    private func config(rules: [FolderConfig.Rule], categories: [FolderConfig.Category] = []) -> FolderConfig {
        FolderConfig(
            plan: .init(dest: "", reviewDir: "_Review", keepDuplicate: "oldest", autoConfidence: 0.85,
                        reviewConfidence: 0.5, maxDepth: 0),
            decider: .init(backend: "none", url: "", model: "", trustChatConfidence: false),
            folders: .init(move: true, kinds: []), rules: rules, categories: categories)
    }

    @Test func theSameRulesReadAgainKeepTheirIDs() {
        let old = config(rules: [.init(name: "a", target: "A"), .init(name: "b", target: "B")],
                         categories: [.init(key: "x"), .init(key: "y")])
        let read = config(rules: [.init(name: "a", target: "A"), .init(name: "b", target: "B")],
                          categories: [.init(key: "x"), .init(key: "y")])
        #expect(read.rules.map(\.id) != old.rules.map(\.id))  // as decoded: new ids
        let kept = read.keepingIDs(of: old)
        #expect(kept.rules.map(\.id) == old.rules.map(\.id))
        #expect(kept.categories.map(\.id) == old.categories.map(\.id))
        #expect(kept == read)
    }

    @Test func aRuleKeepsItsIDWhenItMovesOrChanges() {
        let old = config(rules: [.init(name: "a", target: "A"), .init(name: "b", target: "B"),
                                 .init(name: "c", target: "C")])
        // Revert after editing: b comes back with its old target, the list is in the file's order
        let read = config(rules: [.init(name: "c", target: "C"), .init(name: "b", target: "Elsewhere"),
                                  .init(name: "a", target: "A")])
        let kept = read.keepingIDs(of: old)
        #expect(kept.rules.map(\.id) == [old.rules[2].id, old.rules[1].id, old.rules[0].id])
    }

    @Test func aRenamedRuleKeepsItsPlaceAndANewOneGetsItsOwnID() {
        let old = config(rules: [.init(name: "a", target: "A"), .init(name: "draft", target: "B")])
        let read = config(rules: [.init(name: "a", target: "A"), .init(name: "final", target: "B2"),
                                  .init(name: "new", target: "N")])
        let kept = read.keepingIDs(of: old)
        #expect(kept.rules[0].id == old.rules[0].id)
        #expect(kept.rules[1].id == old.rules[1].id)  // same place, another name and target
        #expect(kept.rules[2].id == read.rules[2].id)
        #expect(Set(kept.rules.map(\.id)).count == 3)
    }

    @Test func aFolderNameIsMatchedWithoutTheSpacesAroundIt() {
        let old = config(rules: [], categories: [.init(key: "money ", path: "Money"), .init(key: "work")])
        let read = config(rules: [], categories: [.init(key: "work"), .init(key: "money", path: "Money")])
        let kept = read.keepingIDs(of: old)  // dewey saved the name trimmed
        #expect(kept.categories.map(\.id) == [old.categories[1].id, old.categories[0].id])
    }
}

@MainActor @Suite(.enabled(if: realDewey != nil, "needs ~/.venvs/dewey (see README)"), .timeLimit(.minutes(1)))
struct SettingsWithDeweyTests {
    @Test func theSelectedRuleIsStillThatRuleAfterSaveAndAfterReadingAgain() async throws {
        let root = try tempFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = FolderSettings(cli: DeweyCLI(executable: realDewey!), root: root.path)
        await settings.load()
        let rule = FolderConfig.Rule(name: "recipes", target: "Documents/Recipes")
        settings.draft?.rules.insert(rule, at: 0)
        let ids = try #require(settings.draft?.rules.map(\.id))
        let folders = try #require(settings.draft?.categories.map(\.id))
        #expect(await settings.save())
        #expect(settings.draft?.rules.map(\.id) == ids)  // 0.2.1: all new, so the editor closed
        #expect(settings.draft?.categories.map(\.id) == folders)
        await settings.load()  // coming back to the app
        #expect(settings.draft?.rules.map(\.id) == ids)
        settings.draft?.rules[0].target = "Elsewhere"
        settings.revert()
        #expect(settings.draft?.rules.map(\.id) == ids)
        #expect(settings.draft?.rules[0].target == "Documents/Recipes")
    }

    @Test func whatIsTypedWhileASaveRunsStaysInTheForm() async throws {
        let root = try tempFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = FolderSettings(cli: DeweyCLI(executable: realDewey!), root: root.path)
        await settings.load()
        settings.draft?.plan.reviewDir = "_Check"
        let save = Task { await settings.save() }
        while !settings.saving { try await Task.sleep(for: .milliseconds(2)) }
        settings.draft?.plan.reviewDir = "_Check These"  // two more words, typed after ⌘S
        await settings.load()                            // and a read that starts meanwhile is not made
        #expect(await save.value)
        #expect(settings.saved?.plan.reviewDir == "_Check")
        #expect(settings.draft?.plan.reviewDir == "_Check These")  // 0.2.1: back to "_Check"
        #expect(settings.hasChanges && settings.canSave)
        #expect(await settings.save())
        let toml = try String(contentsOf: root.appending(path: ".dewey/dewey.toml"), encoding: .utf8)
        #expect(toml.contains("review_dir = \"_Check These\""))
    }

    @Test func aNewFolderShowsTheDefaultsAndSavingAFolderWritesIt() async throws {
        let root = try tempFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = FolderSettings(cli: DeweyCLI(executable: realDewey!), root: root.path)
        await settings.load()
        let file = try #require(settings.file)
        #expect(!file.exists && file.valid && file.sha256 == nil)
        #expect(settings.draft == file.defaults)
        #expect(settings.draft?.categories.first?.key == "finance")
        #expect(settings.draft?.folders.kinds.first?.label == "code project")
        #expect(!settings.hasChanges && !settings.canSave)

        settings.draft?.categories.insert(.init(key: "recipes", path: "Documents/Recipes", desc: "recipes"), at: 0)
        settings.draft?.plan.autoConfidence = 0.9
        #expect(settings.hasChanges && settings.canSave)
        #expect(await settings.save())
        #expect(!settings.hasChanges)
        #expect(settings.file?.exists == true)
        let toml = try String(contentsOf: root.appending(path: ".dewey/dewey.toml"), encoding: .utf8)
        #expect(toml.contains("[categories.recipes]\npath = \"Documents/Recipes\""))
        #expect(toml.contains("auto_confidence = 0.9"))
        #expect(!toml.contains("[[rules]]"))

        // read again from scratch: the same settings, in the same order
        let again = FolderSettings(cli: DeweyCLI(executable: realDewey!), root: root.path)
        await again.load()
        #expect(again.draft == settings.draft)
        #expect(again.draft?.categories.first?.key == "recipes")
    }

    @Test func aFileChangedElsewhereIsntOverwrittenAndChangesAreKept() async throws {
        let root = try tempFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = FolderSettings(cli: DeweyCLI(executable: realDewey!), root: root.path)
        await settings.load()
        let toml = root.appending(path: ".dewey/dewey.toml")
        try FileManager.default.createDirectory(at: toml.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "[plan]\nmax_depth = 2\n".write(to: toml, atomically: true, encoding: .utf8)  // a text editor

        settings.draft?.decider.backend = "none"
        #expect(await settings.save() == false)
        #expect(settings.notice?.contains("changed outside Dewey") == true)
        #expect(settings.draft?.decider.backend == "none", "the change is kept")
        #expect(settings.saved?.plan.maxDepth == 2, "and the file's version is known")
        #expect(await settings.save())
        let text = try String(contentsOf: toml, encoding: .utf8)
        #expect(text.contains("backend = \"none\"") && text.contains("max_depth = 2"))
    }

    @Test func aBrokenFileIsShownAndCanStartOver() async throws {
        let root = try tempFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let toml = root.appending(path: ".dewey/dewey.toml")
        try FileManager.default.createDirectory(at: toml.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "[plan\n".write(to: toml, atomically: true, encoding: .utf8)
        let settings = FolderSettings(cli: DeweyCLI(executable: realDewey!), root: root.path)
        await settings.load()
        #expect(settings.file?.valid == false)
        #expect(settings.file?.raw == "[plan\n")
        #expect(settings.file?.error?.contains("isn't valid TOML") == true)
        #expect(settings.draft == nil && !settings.canSave)

        await settings.reset()
        #expect(settings.file?.valid == true)
        #expect(settings.draft == settings.defaults)
        let kept = try #require(settings.file?.kept)  // a file a person wrote: under a dated name, for good
        let name = (kept as NSString).lastPathComponent
        #expect(name.wholeMatch(of: /dewey\.toml\.\d{4}-\d\d-\d\d\.bak/) != nil)
        #expect(settings.notice == "Back to the defaults. The old file is \(name).")
        #expect(try String(contentsOfFile: kept, encoding: .utf8) == "[plan\n")
    }

    @Test func aFileAPersonWroteIsKeptForGoodWhenTheAppSavesOverIt() async throws {
        let root = try tempFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let toml = root.appending(path: ".dewey/dewey.toml")
        try FileManager.default.createDirectory(at: toml.deletingLastPathComponent(), withIntermediateDirectories: true)
        let mine = "# receipts go to Money\n[plan]\nmax_depth = 2\n"
        try mine.write(to: toml, atomically: true, encoding: .utf8)
        let settings = FolderSettings(cli: DeweyCLI(executable: realDewey!), root: root.path)
        await settings.load()
        settings.draft?.plan.maxDepth = 3
        #expect(await settings.save())
        let kept = try #require(settings.file?.kept)
        #expect(settings.notice == "Saved. The dewey.toml you had is kept next to it as \((kept as NSString).lastPathComponent).")
        for depth in [4, 5] {  // 0.2.0 kept one dewey.toml.bak: the second save replaced the person's file in it
            settings.draft?.plan.maxDepth = depth
            #expect(await settings.save())
            #expect(settings.file?.kept == nil)
            #expect(settings.notice == "Saved. The next Scan & Plan uses these settings.")
        }
        #expect(try String(contentsOfFile: kept, encoding: .utf8) == mine)
    }

    @Test func deweyRefusesWhatTheFormMissed() async throws {
        let root = try tempFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = FolderSettings(cli: DeweyCLI(executable: realDewey!), root: root.path)
        await settings.load()
        var rule = FolderConfig.Rule(name: "broken", target: "X")
        rule.nameRegex = "(unclosed"
        settings.draft?.rules.append(rule)
        #expect(await settings.save() == false)
        guard case .failed(let code, let message) = settings.error else {
            Issue.record("expected a config error, got \(String(describing: settings.error))")
            return
        }
        #expect(code == "config" && message.contains("bad regex in rule broken"))
        #expect(settings.hasChanges)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".dewey/dewey.toml").path))
    }
}
