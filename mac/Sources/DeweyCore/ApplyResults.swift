import Foundation

/// `dewey apply --dry-run`: every row that would move, and every row refused with the reason.
public struct ApplyPreview: Decodable, Sendable, Equatable {
    public struct Item: Decodable, Sendable, Equatable, Identifiable {
        public var row: Int
        public var src: String
        public var dst: String
        public var status: String
        public var category: String
        public var action: String
        public var reason: String?
        public var size: Int64

        public var id: Int { row }
        public var name: String { (src as NSString).lastPathComponent }
        public var isFolder: Bool { action == "folder" }
        /// auto first, then review: the sort order of the Status column.
        public var statusRank: Int { PlanReview.statuses.firstIndex(of: status) ?? 3 }
    }

    public struct Refused: Decodable, Sendable, Equatable, Identifiable {
        public var row: Int
        public var src: String
        public var why: String
        public var id: Int { row }
    }

    public var planId: Int
    public var bytes: Int64
    public var selected: [Item]
    public var refused: [Refused]
    /// Where the rows go (dewey before 0.2.1 doesn't say).
    public var destRoot: String?
    /// That place is outside the folder itself (plan.dest): the files leave it.
    public var destOutside: Bool?

    /// "~/Sorted" when the files leave the folder, for the screen to say so before they move.
    public var leavesFolderFor: String? {
        guard destOutside == true, let destRoot else { return nil }
        return (destRoot as NSString).abbreviatingWithTildeInPath
    }

    public var folders: Int { selected.reduce(0) { $0 + ($1.isFolder ? 1 : 0) } }
    public var files: Int { selected.count - folders }
    public func count(status: String) -> Int { selected.reduce(0) { $0 + ($1.status == status ? 1 : 0) } }
}

/// `dewey apply` for real: what moved, what was skipped (changed or gone since the scan) and what failed.
public struct ApplyResult: Decodable, Sendable, Equatable {
    public struct Counts: Decodable, Sendable, Equatable {
        public var moved = 0
        public var skipped = 0
        public var failed = 0
        public var bytesMoved: Int64 = 0
        public var prunedDirs = 0
    }

    public struct Moved: Decodable, Sendable, Equatable {
        public var from: String
        public var to: String
        /// file or folder (a folder kept whole moves as one).
        public var kind: String?
        public var status: String?
        public var category: String?
        public var size: Int64
    }

    /// A row that didn't move: `why` for skipped rows, `error` for failed ones.
    public struct Problem: Decodable, Sendable, Equatable, Identifiable {
        public var row: Int
        public var src: String
        public var why: String?
        public var error: String?
        public var id: Int { row }
        public var text: String { why ?? error ?? "" }
    }

    /// nil when there was nothing to move.
    public var batch: String?
    public var planId: Int
    public var destRoot: String?
    public var counts: Counts
    public var moved: [Moved]
    public var skipped: [Problem]
    public var failed: [Problem]
    public var prunedDirs: [String]
    public var refused: [ApplyPreview.Refused]

    public var movedFolders: Int { moved.reduce(0) { $0 + ($1.kind == "folder" ? 1 : 0) } }
    /// "4 files and 2 folders".
    public var movedText: String {
        ProgressText.items(files: counts.moved - movedFolders, folders: movedFolders)
    }

    enum CodingKeys: String, CodingKey {
        case batch, planId, destRoot, counts, moved, skipped, failed, prunedDirs, refused
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        batch = try c.decodeIfPresent(String.self, forKey: .batch)
        planId = try c.decode(Int.self, forKey: .planId)
        destRoot = try c.decodeIfPresent(String.self, forKey: .destRoot)
        counts = try c.decodeIfPresent(Counts.self, forKey: .counts) ?? Counts()
        moved = try c.decodeIfPresent([Moved].self, forKey: .moved) ?? []
        skipped = try c.decodeIfPresent([Problem].self, forKey: .skipped) ?? []
        failed = try c.decodeIfPresent([Problem].self, forKey: .failed) ?? []
        prunedDirs = try c.decodeIfPresent([String].self, forKey: .prunedDirs) ?? []
        refused = try c.decodeIfPresent([ApplyPreview.Refused].self, forKey: .refused) ?? []
    }
}

/// `dewey undo`: how many went back, and the ones left where they are (with why).
public struct UndoResult: Decodable, Sendable, Equatable {
    public struct Skipped: Decodable, Sendable, Equatable, Hashable {
        public var path: String
        public var why: String
    }

    public var batch: String
    public var restored: Int
    public var skipped: Int
    public var dirsRemoved: Int
    public var skippedItems: [Skipped]
}
