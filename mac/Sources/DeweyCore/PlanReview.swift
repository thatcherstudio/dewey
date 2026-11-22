import Foundation
import Observation

/// Reviewing one plan: its rows (from `dewey rows`), the changes made here and not saved yet, and
/// what the table shows (filter, search, sort). Save writes the changes into plan-N.csv through
/// `dewey edit`, so the CSV stays the one source of truth and Numbers edits keep working.
@MainActor @Observable
public final class PlanReview {
    public enum Filter: String, CaseIterable, Sendable, Identifiable {
        case all, auto, review, skip, moved, duplicate, folder, changed, problems
        public var id: String { rawValue }
    }

    /// A change made here, not saved yet. nil fields are left as the CSV has them.
    public struct Edit: Equatable, Sendable {
        public var status: String?
        public var category: String?
        public var dst: String?

        public var isEmpty: Bool { status == nil && category == nil && dst == nil }
    }

    /// One line of the table: the row with unsaved changes applied.
    public struct Row: Identifiable, Equatable, Sendable {
        public let id: Int
        public let src: String
        public let name: String
        public let action: String
        public let size: Int64
        public let status: String
        public let dst: String
        public let category: String
        /// -1 when there is none.
        public let confidence: Double
        public let decidedBy: String
        public let reason: String
        public let alternatives: String
        /// From dewey (move, stay, noop, refused, moved) for saved values; a row with unsaved changes
        /// keeps its last verdict until it is saved.
        public let verdict: String
        public let why: String
        /// Differs from what the plan first said (saved in the CSV, or changed here).
        public let changed: Bool
        /// Has changes here that aren't saved.
        public let pending: Bool
        /// `dst` is Dewey's guess at where a new category puts it; saving gives the exact path.
        public let dstIsPreview: Bool

        /// auto, review, skip, then anything else: the sort order of the Status column.
        public var statusRank: Int { PlanReview.statuses.firstIndex(of: status) ?? 3 }
        public var isFolder: Bool { action == "folder" }
        /// A batch moved it and it hasn't been put back: done, and not to be changed here.
        public var isMoved: Bool { verdict == "moved" }
    }

    public nonisolated static let statuses = ["auto", "review", "skip"]

    public let root: String
    public var cli: DeweyCLI
    public private(set) var plan: PlanRows?
    public private(set) var loading = false
    public private(set) var saving = false
    /// Why the plan couldn't be read or saved.
    public private(set) var error: DeweyError?
    /// A one-line note after a save or reload, for the person.
    public var notice: String?
    /// Called after a save that wrote the CSV: the folder's own counts (Overview) are read again.
    @ObservationIgnored public var onSaved: (@MainActor () -> Void)?
    public private(set) var pending: [Int: Edit] = [:]
    public var filter: Filter = .all { didSet { rebuild() } }
    public var search = "" { didSet { rebuild() } }
    public var sortOrder: [KeyPathComparator<Row>] = [] { didSet { rebuild() } }
    /// The table's rows: filtered, searched, sorted.
    public private(set) var visible: [Row] = []
    /// How many rows each filter shows (ignoring the search).
    public private(set) var counts: [Filter: Int] = [:]

    @ObservationIgnored private var all: [Row] = []
    @ObservationIgnored private var byRow: [Int: PlanRow] = [:]

    public init(cli: DeweyCLI, root: String) {
        self.cli = cli
        self.root = root
    }

    public var hasChanges: Bool { !pending.isEmpty }
    public var rootURL: URL { URL(fileURLWithPath: plan?.root ?? root) }

    public func row(_ id: Int) -> PlanRow? { byRow[id] }
    public func displayRow(_ id: Int) -> Row? { all.first { $0.id == id } }

    /// Where a row is on disk now: where the plan found it, or where a batch has put it since.
    public func sourceURL(_ id: Int) -> URL? {
        guard let r = byRow[id] else { return nil }
        if r.verdict == "moved", let plan { return URL(fileURLWithPath: plan.destRoot).appending(path: r.dst) }
        return rootURL.appending(path: r.src)
    }

    /// A row that can still be changed: one that hasn't moved.
    private func canChange(_ id: Int) -> Bool { byRow[id].map { $0.verdict != "moved" } ?? false }

    // MARK: - loading and saving

    /// Read the plan's rows. Without `planId`, the latest plan; changes made here for another plan
    /// are dropped, for the same plan they are kept on top of the CSV as it is now.
    public func load(planId: Int? = nil) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let rows = try await cli.run(["rows", root] + (planId.map { ["--plan", String($0)] } ?? []),
                                         as: PlanRows.self)
            show(rows)
        } catch let e as DeweyError {
            error = e
            rebuild()
        } catch {
            self.error = .launch(error.localizedDescription)
            rebuild()
        }
    }

    /// Show freshly read rows, keeping unsaved changes when they are for the same plan.
    func show(_ rows: PlanRows) {
        if rows.planId != plan?.planId { pending = [:] }
        plan = rows
        byRow = Dictionary(uniqueKeysWithValues: rows.rows.map { ($0.row, $0) })
        pending = pending.filter { canChange($0.key) }  // gone from the plan, or moved since
        for id in Array(pending.keys) { normalize(id) }
        error = nil
        rebuild()
    }

    /// Reload the same plan (Numbers may have saved it), and say so if it changed.
    public func reload() async {
        let before = plan
        await load(planId: plan?.planId)
        if let before, let now = plan, now.planId == before.planId, now.csvSha256 != before.csvSha256 {
            notice = "Showing \((now.csv as NSString).lastPathComponent) as it was just saved outside Dewey."
        }
    }

    /// The edits `dewey edit` reads on stdin, in row order.
    public func editsJSON() -> Data {
        let list: [[String: Any]] = pending.keys.sorted().map { id in
            let e = pending[id]!
            var d: [String: Any] = ["row": id]
            if let s = e.status { d["status"] = s }
            if let c = e.category { d["category"] = c }
            if let t = e.dst { d["dst"] = t }
            return d
        }
        return (try? JSONSerialization.data(withJSONObject: list, options: [.sortedKeys])) ?? Data("[]".utf8)
    }

    /// Write the changes into plan-N.csv. If the file changed since it was read (saved from Numbers),
    /// nothing is written: the plan is reloaded with the changes kept, to look over and save again.
    @discardableResult
    public func save() async -> Bool {
        guard let plan, hasChanges, !saving else { return false }
        saving = true
        defer { saving = false }
        let n = pending.count
        do {
            let res = try await cli.run(["edit", root, "--plan", String(plan.planId), "--expect-sha", plan.csvSha256],
                                        stdin: editsJSON(), as: EditResult.self)
            pending = [:]
            await load(planId: plan.planId)
            notice = "Saved \(n) \(n == 1 ? "change" : "changes") to \((res.csv as NSString).lastPathComponent)."
            onSaved?()
            return true
        } catch DeweyError.failed(code: "stale", message: _) {
            await load(planId: plan.planId)
            notice = "\((plan.csv as NSString).lastPathComponent) was changed outside Dewey (saved from Numbers?). "
                + "Dewey reloaded it and kept your changes: look them over and save again."
            return false
        } catch let e as DeweyError {
            error = e
            return false
        } catch {
            self.error = .launch(error.localizedDescription)
            return false
        }
    }

    public func discardChanges() {
        pending = [:]
        rebuild()
    }

    // MARK: - changes

    /// Approve = auto (moves on apply), reject = skip (stays), review = moves only if review rows are included.
    public func setStatus(_ status: String, for ids: some Sequence<Int>) {
        precondition(Self.statuses.contains(status), "status must be auto, review or skip")
        for id in ids where canChange(id) {
            pending[id, default: Edit()].status = status
            normalize(id)
        }
        rebuild()
    }

    public func setCategory(_ category: String, for ids: some Sequence<Int>) {
        for id in ids where canChange(id) {
            pending[id, default: Edit()].category = category
            normalize(id)
        }
        rebuild()
    }

    /// A typed destination, relative to the destination root. Ending in "/" means "into this folder".
    public func setDestination(_ dst: String, for id: Int) {
        let t = dst.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canChange(id), !t.isEmpty else { return }
        pending[id, default: Edit()].dst = t
        normalize(id)
        rebuild()
    }

    /// Back to what the plan first said.
    public func revertToPlan(_ ids: some Sequence<Int>) {
        for id in ids {
            guard let r = byRow[id], canChange(id) else { continue }
            pending[id] = Edit(status: r.planned.status, category: r.planned.category,
                               dst: r.dst == r.planned.dst ? nil : r.planned.dst)
            normalize(id)
        }
        rebuild()
    }

    /// Forget unsaved changes to these rows.
    public func undoChanges(_ ids: some Sequence<Int>) {
        for id in ids { pending[id] = nil }
        rebuild()
    }

    /// Drop fields that equal what the CSV already says, and empty edits.
    private func normalize(_ id: Int) {
        guard var e = pending[id], let r = byRow[id] else { return }
        if e.status == r.status { e.status = nil }
        if e.category == r.category { e.category = nil }
        if e.dst == r.dst { e.dst = nil }
        pending[id] = e.isEmpty ? nil : e
    }

    // MARK: - categories

    /// What a row's category can be set to: the folder keys, plus the [folders] kinds for a whole
    /// folder, plus whatever it is now (a rule name, "duplicate").
    public func categoryChoices(for id: Int) -> [String] {
        guard let plan, let r = byRow[id] else { return [] }
        var keys = plan.categories.map(\.key)
        if r.action == "folder" { keys = plan.folderKinds.map(\.kind) + keys.filter { k in !plan.folderKinds.contains { $0.kind == k } } }
        let current = pending[id]?.category ?? r.category
        for extra in [r.planned.category, current] where !keys.contains(extra) { keys.insert(extra, at: 0) }
        return keys
    }

    /// The folder a category files into ("" = leaves it where it is, nil = not a category).
    public func home(of category: String, folder: Bool) -> String? {
        guard let plan else { return nil }
        if folder, let k = plan.folderKinds.first(where: { $0.kind == category }) { return k.path }
        return plan.categories.first { $0.key == category }?.path
    }

    // MARK: - the table

    private func display(_ r: PlanRow) -> Row {
        let e = pending[r.row]
        let status = e?.status ?? r.status
        let category = e?.category ?? r.category
        var dst = e?.dst ?? r.dst
        var preview = false
        if let typed = e?.dst, typed.hasSuffix("/") {
            dst = typed + r.name
        } else if e?.dst == nil, let c = e?.category, c != r.planned.category,
                  let home = home(of: c, folder: r.action == "folder") {
            // what apply does with a new category and the planned dst (mover.resolve_row)
            dst = home.isEmpty ? r.src : "\(home.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(r.name)"
            preview = true
        } else if e?.dst == nil, e?.category == r.planned.category, r.category != r.planned.category {
            dst = r.planned.dst
            preview = true
        }
        var changed = r.edited
        if let e {  // a typed dst in the CSV that this edit leaves alone still counts
            let dstChanged = e.dst.map { $0 != r.planned.dst }
                ?? (r.edited && r.category == r.planned.category && r.dst != r.planned.dst)
            changed = status != r.planned.status || category != r.planned.category || dstChanged
        }
        return Row(id: r.row, src: r.src, name: r.name, action: r.action, size: r.size, status: status, dst: dst,
                   category: category, confidence: r.confidence ?? -1, decidedBy: r.decidedBy ?? "",
                   reason: r.reason ?? "", alternatives: r.alternatives ?? "", verdict: r.verdict, why: r.why,
                   changed: changed, pending: e != nil, dstIsPreview: preview)
    }

    public func matches(_ row: Row, _ filter: Filter) -> Bool {
        switch filter {
        case .all: true
        case .auto, .review, .skip: row.status == filter.rawValue && !row.isMoved
        case .moved: row.isMoved
        case .duplicate: row.action == "duplicate"
        case .folder: row.action == "folder"
        case .changed: row.changed
        case .problems: row.verdict == "refused"
        }
    }

    private func rebuild() {
        all = (plan?.rows ?? []).map(display)
        var c: [Filter: Int] = [:]
        for f in Filter.allCases { c[f] = all.reduce(0) { $0 + (matches($1, f) ? 1 : 0) } }
        counts = c
        let q = search.trimmingCharacters(in: .whitespaces)
        var rows = all.filter { matches($0, filter) }
        if !q.isEmpty {
            rows = rows.filter {
                $0.src.localizedCaseInsensitiveContains(q) || $0.dst.localizedCaseInsensitiveContains(q)
                    || $0.category.localizedCaseInsensitiveContains(q) || $0.reason.localizedCaseInsensitiveContains(q)
            }
        }
        if !sortOrder.isEmpty { rows.sort(using: sortOrder) }
        visible = rows
    }
}
