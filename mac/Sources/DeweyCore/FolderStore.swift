import Foundation
import Observation

/// The folders in the sidebar, in the person's order, kept in UserDefaults.
@MainActor @Observable
public final class FolderStore {
    public private(set) var paths: [String]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "folders") {
        self.defaults = defaults
        self.key = key
        var seen = Set<String>()
        paths = (defaults.stringArray(forKey: key) ?? []).filter { seen.insert($0).inserted }
    }

    /// The form dewey itself uses for a root (`Path.resolve()`): absolute, symlinks resolved, so
    /// /tmp/x and /private/tmp/x are one folder.
    /// (Not `resolvingSymlinksInPath()`: that strips /private, the opposite of what dewey does.)
    public nonisolated static func normalize(_ url: URL) -> String {
        var p = url.standardizedFileURL.path
        if let real = realpath(p, nil) {  // nil for a path that doesn't exist: keep it as given
            p = String(cString: real)
            free(real)
        }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Adds a folder at the top (or moves it there if it's already listed) and returns its path.
    @discardableResult
    public func add(_ url: URL) -> String {
        let p = Self.normalize(url)
        paths.removeAll { $0 == p }
        paths.insert(p, at: 0)
        save()
        return p
    }

    /// Takes a folder off the list. Its files and its .dewey folder are left alone.
    public func remove(_ path: String) {
        paths.removeAll { $0 == path }
        save()
    }

    /// Same meaning as SwiftUI's `move(fromOffsets:toOffset:)` (List's drag to reorder).
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { paths[$0] }
        var rest = paths.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let at = destination - source.filter { $0 < destination }.count
        rest.insert(contentsOf: moving, at: max(0, min(at, rest.count)))
        paths = rest
        save()
    }

    private func save() {
        defaults.set(paths, forKey: key)
    }
}
