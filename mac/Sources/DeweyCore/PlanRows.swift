import Foundation

/// `dewey rows ROOT [--plan N]`: every row of a plan as apply would see it now, with the CSV's edits.
public struct PlanRows: Decodable, Sendable, Equatable {
    public struct Category: Decodable, Sendable, Equatable, Hashable {
        public var key: String
        /// "" for a leave-it-where-it-is category ("other").
        public var path: String
        public var desc: String
    }

    /// A `[folders]` kind: where a whole folder of that kind goes ("" = labelled, left in place).
    public struct FolderKind: Decodable, Sendable, Equatable, Hashable {
        public var kind: String
        public var path: String
    }

    public var planId: Int
    public var created: String
    public var decider: String?
    public var root: String
    public var destRoot: String
    public var csv: String
    public var report: String?
    /// Sent back with `dewey edit --expect-sha`, so an edit never overwrites a save from Numbers.
    public var csvSha256: String
    public var summary: PlanSummary
    /// In config order (the decider sees them in this order).
    public var categories: [Category]
    public var folderKinds: [FolderKind]
    public var autoConfidence: Double
    public var reviewConfidence: Double
    public var rows: [PlanRow]
}

public struct PlanRow: Decodable, Sendable, Equatable, Identifiable {
    public struct Planned: Decodable, Sendable, Equatable {
        public var status: String
        public var dst: String
        public var category: String
    }

    public var row: Int
    /// Relative to the plan's root.
    public var src: String
    /// move | duplicate | folder (a whole folder that moves as one).
    public var action: String
    public var size: Int64
    /// auto | review | skip as the CSV says now (anything else is refused by apply).
    public var status: String
    /// Where apply will put it, relative to the destination root.
    public var dst: String
    public var category: String
    /// move | stay (a leave-it-here category) | noop (already there) | refused.
    public var verdict: String
    /// Why a row is refused or stays.
    public var why: String
    /// false: the line was deleted from the CSV (which means skip).
    public var inCsv: Bool
    /// The CSV differs from what the plan first said.
    public var edited: Bool
    public var planned: Planned
    public var confidence: Double?
    public var decidedBy: String?
    public var reason: String?
    public var alternatives: String?

    public var id: Int { row }
    public var name: String { (src as NSString).lastPathComponent }
}

/// `dewey edit`.
public struct EditResult: Decodable, Sendable, Equatable {
    public var planId: Int
    public var csv: String
    public var csvSha256: String
    public var changed: Int
}
