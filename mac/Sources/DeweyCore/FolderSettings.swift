import Foundation
import Observation

/// One folder's settings as the app edits them (`dewey config`): the decider's folders
/// (categories), rules, thresholds, folder kinds and the decider. Settings the app doesn't show
/// (the scan's skip lists, worker counts…) aren't here and are left as they are on save.
public struct FolderConfig: Codable, Sendable, Equatable {
    public struct Plan: Codable, Sendable, Equatable {
        /// "" = organize inside the folder itself.
        public var dest: String
        public var reviewDir: String
        /// oldest, newest or shortest_path: which copy of a duplicate stays put.
        public var keepDuplicate: String
        public var autoConfidence: Double
        public var reviewConfidence: Double
        /// 0 = only loose files move, N = files up to N folders deep, -1 = every file.
        public var maxDepth: Int
    }

    public struct Decider: Codable, Sendable, Equatable {
        /// systemone (Laya), chat (an OpenAI-compatible server) or none (rules only).
        public var backend: String
        public var url: String
        public var model: String
        public var trustChatConfidence: Bool
    }

    public struct FolderKind: Codable, Sendable, Equatable, Identifiable {
        public var kind: String
        /// "" = label it, leave it where it is.
        public var path: String
        public var label: String?
        public var id: String { kind }
    }

    public struct Folders: Codable, Sendable, Equatable {
        public var move: Bool
        public var kinds: [FolderKind]
    }

    /// A folder the decider can choose: `key` is its answer, `desc` what it reads.
    public struct Category: Codable, Sendable, Equatable, Identifiable {
        public var key: String
        /// "" = leave the file where it is.
        public var path: String
        public var desc: String
        /// For the list only (a key can be blank or repeated while it's typed).
        public var id = UUID()

        public init(key: String = "", path: String = "", desc: String = "") {
            self.key = key
            self.path = path
            self.desc = desc
        }

        enum CodingKeys: String, CodingKey { case key, path, desc }

        public static func == (a: Self, b: Self) -> Bool { a.key == b.key && a.path == b.path && a.desc == b.desc }
    }

    /// A rule: every condition given must match; first matching rule wins.
    public struct Rule: Codable, Sendable, Equatable, Identifiable {
        public var name: String
        public var target: String
        public var reason: String?
        public var ext: [String]?
        public var nameRegex: String?
        public var pathRegex: String?
        public var minSize: Int64?
        public var maxSize: Int64?
        public var hasCamera: Bool?
        public var id = UUID()

        public init(name: String = "", target: String = "") {
            self.name = name
            self.target = target
        }

        enum CodingKeys: String, CodingKey {
            case name, target, reason, ext, nameRegex, pathRegex, minSize, maxSize, hasCamera
        }

        public static func == (a: Self, b: Self) -> Bool {
            a.name == b.name && a.target == b.target && a.reason == b.reason && a.ext == b.ext
                && a.nameRegex == b.nameRegex && a.pathRegex == b.pathRegex && a.minSize == b.minSize
                && a.maxSize == b.maxSize && a.hasCamera == b.hasCamera
        }

        /// "ext .dmg .pkg, name ^Screenshot", for the list.
        public var matchSummary: String {
            var parts: [String] = []
            if let ext, !ext.isEmpty { parts.append(ext.joined(separator: " ")) }
            if let nameRegex { parts.append("name ~ \(nameRegex)") }
            if let pathRegex { parts.append("path ~ \(pathRegex)") }
            if let minSize { parts.append("≥ \(ProgressText.bytes(minSize))") }
            if let maxSize { parts.append(maxSize == 0 ? "empty" : "≤ \(ProgressText.bytes(maxSize))") }
            if let hasCamera { parts.append(hasCamera ? "from a camera" : "not from a camera") }
            return parts.isEmpty ? "every file" : parts.joined(separator: ", ")
        }
    }

    public var plan: Plan
    public var decider: Decider
    public var folders: Folders
    public var rules: [Rule]
    public var categories: [Category]

    /// What needs fixing before these can be saved (dewey checks again, this is for the form).
    public var problems: [String] {
        var out: [String] = []
        if plan.reviewConfidence > plan.autoConfidence {
            out.append("The Review threshold has to be at or below the Move threshold.")
        }
        let keys = categories.map { $0.key.trimmingCharacters(in: .whitespaces) }
        if keys.contains("") { out.append("Every folder needs a name.") }
        var seen = Set<String>()
        for k in keys where !k.isEmpty && !seen.insert(k).inserted {
            out.append("Two folders are called “\(k)”.")
        }
        if decider.backend != "none" && categories.count < 2 {
            out.append("The model needs at least 2 folders to choose from.")
        }
        for (i, r) in rules.enumerated()
        where r.name.trimmingCharacters(in: .whitespaces).isEmpty || r.target.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append("Rule \(i + 1)\(r.name.isEmpty ? "" : " (\(r.name))") needs a name and a destination.")
        }
        return out
    }

    /// The JSON `dewey config --write` reads (snake_case keys, nil fields left out).
    public func json() throws -> Data {
        var copy = self
        for i in copy.categories.indices {
            copy.categories[i].key = copy.categories[i].key.trimmingCharacters(in: .whitespaces)
        }
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys]
        return try e.encode(copy)
    }

    /// These settings with the list ids of `old` wherever a rule or folder is the one `old` had. Every
    /// read from dewey makes new ids; without this the rule selected in the list, or the field being
    /// typed in, is let go of each time the settings are read again (after Save, coming back to the app).
    public func keepingIDs(of old: FolderConfig?) -> FolderConfig {
        guard let old else { return self }
        var out = self
        let rules = Self.ids(for: rules, from: old.rules, id: \.id, name: \.name)
        for i in out.rules.indices { out.rules[i].id = rules[i] }
        let categories = Self.ids(for: categories, from: old.categories, id: \.id) {
            $0.key.trimmingCharacters(in: .whitespaces)
        }
        for i in out.categories.indices { out.categories[i].id = categories[i] }
        return out
    }

    /// The id each of `new` gets: that of the same item in `old`, else of one with the same name, else
    /// of the one in the same place (renamed and changed), else its own.
    private static func ids<T: Equatable>(for new: [T], from old: [T], id: KeyPath<T, UUID>,
                                          name: (T) -> String) -> [UUID] {
        var free = Array(old.indices)
        var out = [UUID?](repeating: nil, count: new.count)
        func take(_ i: Int, where match: (Int) -> Bool) {
            guard out[i] == nil, let at = free.firstIndex(where: match) else { return }
            out[i] = old[free.remove(at: at)][keyPath: id]
        }
        for i in new.indices { take(i) { old[$0] == new[i] } }
        for i in new.indices { take(i) { name(old[$0]) == name(new[i]) } }
        for i in new.indices { take(i) { $0 == i } }
        return zip(out, new).map { $0 ?? $1[keyPath: id] }
    }

    /// Only what changed since `base`, for `dewey config --write` to lay over the file as it is now:
    /// a setting changed in a text editor meanwhile stays, unless it was changed here too. Rules and
    /// categories go whole (their order matters).
    public func changes(from base: FolderConfig) throws -> Data {
        func object(_ s: FolderConfig) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: s.json()) as? [String: Any] ?? [:]
        }
        func same(_ a: Any?, _ b: Any?) -> Bool { (a as? NSObject)?.isEqual(b) ?? (b == nil) }
        let new = try object(self), old = try object(base)
        var out: [String: Any] = [:]
        for (section, value) in new {
            switch section {
            case "rules", "categories":
                if !same(value, old[section]) { out[section] = value }
            case "folders":
                let n = value as? [String: Any] ?? [:], o = old[section] as? [String: Any] ?? [:]
                var f: [String: Any] = [:]
                if !same(n["move"], o["move"]) { f["move"] = n["move"] }
                let oldKinds = o["kinds"] as? [[String: Any]] ?? []
                let kinds = (n["kinds"] as? [[String: Any]] ?? []).filter { k in
                    !oldKinds.contains { same($0["kind"], k["kind"]) && same($0["path"], k["path"]) }
                }
                if !kinds.isEmpty { f["kinds"] = kinds }
                if !f.isEmpty { out[section] = f }
            default:
                let n = value as? [String: Any] ?? [:], o = old[section] as? [String: Any] ?? [:]
                let diff = n.filter { !same($0.value, o[$0.key]) }
                if !diff.isEmpty { out[section] = diff }
            }
        }
        return try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
    }
}

/// `dewey config ROOT`: where the settings live and what they are. A file dewey can't use comes
/// back with `valid` false, its error and text (and no `config`), to show and repair.
public struct SettingsFile: Decodable, Sendable, Equatable {
    /// Where saving writes: the folder's own .dewey/dewey.toml.
    public var path: String
    public var exists: Bool
    /// The file read now: `path`, a shared ~/.config/dewey/dewey.toml, or nil (the defaults).
    public var source: String?
    /// Of `path`; nil when there's no file yet.
    public var sha256: String?
    public var valid: Bool
    public var error: String?
    public var raw: String?
    public var config: FolderConfig?
    public var defaults: FolderConfig
    /// After a save: where the file it replaced was kept (dewey.toml.bak, or `kept`).
    public var backup: String?
    /// After a save that replaced a file a person wrote (comments, their own layout): the copy of it,
    /// under a dated name that no later save replaces. nil when the file replaced was the app's own.
    public var kept: String?
}

/// The Settings tab: the folder's settings, the changes made here, and Save.
@MainActor @Observable
public final class FolderSettings {
    public let root: String
    public var cli: DeweyCLI
    public private(set) var file: SettingsFile?
    /// What the form shows and edits.
    public var draft: FolderConfig?
    /// The file's settings as last read.
    public private(set) var saved: FolderConfig?
    /// What `draft` was made from: Save sends only the changes since then.
    @ObservationIgnored private var base: FolderConfig?
    public private(set) var loading = false
    public private(set) var saving = false
    public private(set) var error: DeweyError?
    /// A one-line note after a save or reload, for the person.
    public var notice: String?

    public init(cli: DeweyCLI, root: String) {
        self.cli = cli
        self.root = root
    }

    public var hasChanges: Bool { draft != nil && draft != saved }
    public var problems: [String] { draft?.problems ?? [] }
    public var canSave: Bool { hasChanges && problems.isEmpty && !saving && !loading }
    public var defaults: FolderConfig? { file?.defaults }

    /// Read the settings. Changes made here are kept (unless `discarding`): a file edited elsewhere
    /// then shows when they're reverted.
    public func load(discarding: Bool = false) async {
        // Not during a save: this read could be of the file from before it, and land after it.
        guard !loading, !saving else { return }
        loading = true
        defer { loading = false }
        do {
            show(try await cli.run(["config", root], as: SettingsFile.self), keepDraft: !discarding)
        } catch {
            self.error = error as? DeweyError ?? .launch(error.localizedDescription)
        }
    }

    private func show(_ f: SettingsFile, keepDraft: Bool) {
        let before = file
        file = f
        error = nil
        let changed = hasChanges
        let config = f.config?.keepingIDs(of: draft)
        saved = config
        if !(keepDraft && changed) {
            draft = config
            base = config
            if before?.sha256 != f.sha256 { notice = nil }  // "Saved." is about a file that's gone
        }
        if keepDraft, changed, let before, before.sha256 != f.sha256 {
            notice = "dewey.toml was changed outside Dewey. Revert shows that version; Save replaces it with yours."
        }
    }

    /// Write the changes to the folder's dewey.toml. If the file changed since it was read, nothing
    /// is written: it's read again, the changes kept, to look over and save again. What is typed while
    /// the save runs stays in the form, as changes since what was saved.
    @discardableResult
    public func save() async -> Bool {
        guard let draft, let file, let base, canSave else { return false }
        saving = true
        defer { saving = false }
        do {
            let res = try await cli.run(["config", root, "--write", "--expect-sha", file.sha256 ?? "none"],
                                        stdin: try draft.changes(from: base), as: SettingsFile.self)
            let config = res.config?.keepingIDs(of: self.draft)
            self.file = res
            saved = config
            self.base = config
            if self.draft == draft { self.draft = config }
            error = nil
            notice = res.kept.map { "Saved. The dewey.toml you had is kept next to it as \(($0 as NSString).lastPathComponent)." }
                ?? "Saved. The next Scan & Plan uses these settings."
            return true
        } catch DeweyError.failed(code: "stale", message: _) {
            saving = false
            await load()
            notice = "dewey.toml was changed outside Dewey, so nothing was saved. Your changes are still here: "
                + "Save again to replace that version, or Revert to see it."
            return false
        } catch {
            self.error = error as? DeweyError ?? .launch(error.localizedDescription)
            return false
        }
    }

    /// Start over from dewey's defaults (the file it replaces is kept next to it: see `SettingsFile.kept`).
    public func reset() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            let res = try await cli.run(["config", root, "--write", "--reset"], stdin: Data("{}".utf8),
                                        as: SettingsFile.self)
            let config = res.config?.keepingIDs(of: draft)
            file = res
            saved = config
            draft = config
            base = config
            error = nil
            notice = res.backup.map { "Back to the defaults. The old file is \(($0 as NSString).lastPathComponent)." }
        } catch {
            self.error = error as? DeweyError ?? .launch(error.localizedDescription)
        }
    }

    public func clearError() { error = nil }

    public func revert() {
        draft = saved
        base = saved
        notice = nil
    }
}
