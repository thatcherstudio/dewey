import Foundation

/// Whether a folder is one Dewey should organize.
///
/// dewey refuses the same places itself (`catalog.unsafe_root` in the Python): this check is so the
/// person hears it when they add the folder, not when the first scan fails. Keep the two in step.
public enum RootCheck: Equatable, Sendable {
    case ok
    /// Allowed, after asking: the whole home folder.
    case confirm(String)
    /// Never: the system's folders, the Library, anything that holds the home folder.
    case refuse(String)

    /// These and everything inside them.
    static let systemTrees = ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/etc", "/dev"]
    /// These themselves; folders inside them are fine.
    static let systemFolders = ["/private", "/var", "/tmp", "/opt", "/Volumes"]
    /// In ~/Library: iCloud Drive, Dropbox, Google Drive… Their folders hold the person's own files.
    static let cloudFolders: Set<String> = ["Mobile Documents", "CloudStorage"]

    /// `path` and `home` as `FolderStore.normalize` gives them (absolute, symlinks resolved).
    public static func check(_ path: String, home: String = FolderStore.normalize(URL(fileURLWithPath: NSHomeDirectory()))) -> RootCheck {
        func inside(_ p: String, _ dir: String) -> Bool { p.hasPrefix(dir == "/" ? "/" : dir + "/") }
        let real = { (p: String) in FolderStore.normalize(URL(fileURLWithPath: p)) }

        if path == "/" { return .refuse("Everything on this Mac is in it, the system included.") }
        if inside(home, path) { return .refuse("It holds your whole home folder, and everyone else's.") }
        let library = home + "/Library"
        if path == library || inside(path, library) {
            let parts = path.dropFirst(library.count).split(separator: "/")
            if !(parts.count >= 2 && cloudFolders.contains(String(parts[0]))) {  // ~/Library/CloudStorage/Dropbox is fine
                return .refuse("It is in your Library, where apps keep their own files.")
            }
        }
        if systemTrees.map(real).contains(where: { path == $0 || inside(path, $0) })
            || systemFolders.map(real).contains(path) {
            return .refuse("It belongs to the system.")
        }
        if path == home {
            return .confirm("Dewey plans the loose files at the top of your home folder and suggests a home for each "
                            + "folder in it. Hidden files and folders are left alone. A folder inside it, like "
                            + "Downloads or Desktop, is usually the one to add.")
        }
        return .ok
    }
}
