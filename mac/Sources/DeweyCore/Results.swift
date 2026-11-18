import Foundation

// Result payloads of protocol 1 (`result.data` of the closing event). Decode them with
// `DeweyEvent.decoder()`, which maps dewey's snake_case keys (`plan_id` → `planId`).

/// A count of rows or files and their total size.
public struct Bucket: Decodable, Sendable, Equatable {
    public var n: Int
    public var bytes: Int64

    public init(n: Int = 0, bytes: Int64 = 0) {
        self.n = n
        self.bytes = bytes
    }
}

/// A plan's counts by status (planner.summarize). `duplicate` rows are also counted under their status;
/// `folder` rows are whole folders moved as one, so they are counted on their own.
public struct PlanSummary: Decodable, Sendable, Equatable {
    public var auto = Bucket()
    public var review = Bucket()
    public var skip = Bucket()
    public var duplicate = Bucket()
    public var folder = Bucket()

    public init() {}

    enum CodingKeys: String, CodingKey { case auto, review, skip, duplicate, folder }

    public init(from decoder: Decoder) throws {  // an interrupted plan stores "{}"
        let c = try decoder.container(keyedBy: CodingKeys.self)
        auto = try c.decodeIfPresent(Bucket.self, forKey: .auto) ?? Bucket()
        review = try c.decodeIfPresent(Bucket.self, forKey: .review) ?? Bucket()
        skip = try c.decodeIfPresent(Bucket.self, forKey: .skip) ?? Bucket()
        duplicate = try c.decodeIfPresent(Bucket.self, forKey: .duplicate) ?? Bucket()
        folder = try c.decodeIfPresent(Bucket.self, forKey: .folder) ?? Bucket()
    }
}

public struct PathError: Decodable, Sendable, Equatable, Hashable {
    public var path: String
    public var error: String
}

/// `dewey scan ROOT`.
public struct ScanResult: Decodable, Sendable, Equatable {
    public var scanId: Int
    public var files: Int
    public var bytes: Int64
    public var hashed: Int
    public var reused: Int
    /// App bundles and code projects, catalogued as one item each.
    public var units: Int
    /// iCloud files that aren't downloaded (skipped, never fetched).
    public var cloud: Int
    public var missing: Int
    public var errors: Int
    /// The first 50 errors.
    public var errorItems: [PathError]
}

/// `dewey plan ROOT`.
public struct PlanResult: Decodable, Sendable, Equatable {
    public var planId: Int
    public var csv: String
    public var report: String
    public var summary: PlanSummary
}

/// `dewey status ROOT`. A folder dewey hasn't scanned has `catalog == false` and nothing else.
public struct FolderStatus: Decodable, Sendable, Equatable {
    public struct Scan: Decodable, Sendable, Equatable {
        public var id: Int
        public var started: String
        public var finished: String?
        public var files: Int?
        public var bytes: Int64?
        public var hashed: Int?
        public var reused: Int?
        public var units: Int?
        public var missing: Int?
        public var errors: Int?
    }

    public struct Kind: Decodable, Sendable, Equatable {
        public var kind: String
        public var n: Int
        public var bytes: Int64
    }

    public struct Duplicates: Decodable, Sendable, Equatable {
        /// Files that have at least one exact copy.
        public var groups: Int
        /// Copies beyond the first of each.
        public var copies: Int
        /// Bytes those copies take up.
        public var wasted: Int64

        public init(groups: Int = 0, copies: Int = 0, wasted: Int64 = 0) {
            self.groups = groups
            self.copies = copies
            self.wasted = wasted
        }
    }

    public struct FileType: Decodable, Sendable, Equatable {
        public var ext: String
        public var n: Int
        public var bytes: Int64
    }

    public struct Plan: Decodable, Sendable, Equatable, Identifiable {
        public var id: Int
        public var created: String
        public var decider: String?
        public var csv: String?
        public var report: String?
        public var summary: PlanSummary
    }

    public struct Batch: Decodable, Sendable, Equatable {
        public var batch: String
        public var moves: Int
        public var undone: Int
        public var planId: Int?
        public var movedAt: String?
    }

    public struct LabelCount: Decodable, Sendable, Equatable {
        public var source: String
        public var n: Int
    }

    public var catalog: Bool
    public var root: String
    public var state: String
    /// The last finished scan.
    public var scan: Scan?
    public var kinds: [Kind]
    public var duplicates: Duplicates
    /// The biggest file types by total size, largest first.
    public var topTypes: [FileType]
    /// Newest first.
    public var plans: [Plan]
    /// Newest first.
    public var batches: [Batch]
    /// The newest batch that still has files to put back.
    public var undoable: String?
    public var labels: [LabelCount]
    /// Errors from the last scan (the first 20).
    public var errors: [PathError]

    enum CodingKeys: String, CodingKey {
        case catalog, root, state, scan, kinds, duplicates, topTypes, plans, batches, undoable, labels, errors
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        catalog = try c.decode(Bool.self, forKey: .catalog)
        root = try c.decode(String.self, forKey: .root)
        state = try c.decode(String.self, forKey: .state)
        scan = try c.decodeIfPresent(Scan.self, forKey: .scan)
        kinds = try c.decodeIfPresent([Kind].self, forKey: .kinds) ?? []
        duplicates = try c.decodeIfPresent(Duplicates.self, forKey: .duplicates) ?? Duplicates()
        topTypes = try c.decodeIfPresent([FileType].self, forKey: .topTypes) ?? []
        plans = try c.decodeIfPresent([Plan].self, forKey: .plans) ?? []
        batches = try c.decodeIfPresent([Batch].self, forKey: .batches) ?? []
        undoable = try c.decodeIfPresent(String.self, forKey: .undoable)
        labels = try c.decodeIfPresent([LabelCount].self, forKey: .labels) ?? []
        errors = try c.decodeIfPresent([PathError].self, forKey: .errors) ?? []
    }

    public var latestPlan: Plan? { plans.first }

    /// Items of one kind in the catalog: file, bundle, project, symlink, cloud…
    public func count(_ kind: String) -> Int {
        kinds.first(where: { $0.kind == kind })?.n ?? 0
    }
}

/// dewey writes local times with an offset: `2026-11-17T20:56:32-05:00`.
public enum DeweyDate {
    public static func parse(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }
}
