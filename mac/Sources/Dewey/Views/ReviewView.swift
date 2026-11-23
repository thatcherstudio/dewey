import AppKit
import DeweyCore
import QuickLook
import SwiftUI

/// The Review tab: makes the folder's PlanReview on first use.
struct ReviewTab: View {
    let folder: FolderModel

    var body: some View {
        if let review = folder.review {
            ReviewView(folder: folder, review: review)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                .task { folder.makeReview() }
        }
    }
}

/// Every row of the latest plan in a table. Approve, reject, change category or destination, then
/// Save: the changes go into plan-N.csv, the same file Numbers edits.
struct ReviewView: View {
    let folder: FolderModel
    @Bindable var review: PlanReview
    @State private var selection = Set<Int>()
    @State private var showInspector = true
    @State private var previewURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            if let plan = review.plan {
                messages
                FilterBar(review: review, selection: $selection, reveal: reveal)
                Divider()
                table(plan)
                if review.hasChanges { unsavedBar(plan) }
            } else if review.loading {
                ProgressView("Reading the plan…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = review.error {
                noPlan(error)
            }
        }
        .searchable(text: $review.search, placement: .toolbar, prompt: "Search")
        .inspector(isPresented: $showInspector) {
            RowInspector(review: review, selection: $selection, quickLook: quickLook, reveal: reveal)
                .inspectorColumnWidth(min: 250, ideal: 290, max: 460)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Details", systemImage: "sidebar.trailing")
                }
                .help("Show or hide the details of the selected rows")
            }
        }
        .quickLookPreview($previewURL)
        .task { if review.plan == nil { await review.load() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // back from Numbers: show its edits. With unsaved changes here, Save notices instead.
            if !review.hasChanges { Task { await review.reload() } }
        }
        .onChange(of: review.visible) { _, rows in
            let shown = Set(rows.map(\.id))
            if !selection.isSubset(of: shown) { selection.formIntersection(shown) }
        }
    }

    // MARK: - parts

    @ViewBuilder
    private var messages: some View {
        if let error = review.error {
            Notice(systemImage: "exclamationmark.triangle.fill", tint: .red, text: error.errorDescription ?? "\(error)") {
                Button("Reload") { Task { await review.reload() } }
            }
            .padding([.horizontal, .top], 12)
        } else if let notice = review.notice {
            Notice(systemImage: "info.circle", tint: .blue, text: notice) {
                Button("OK") { review.notice = nil }
            }
            .padding([.horizontal, .top], 12)
        }
    }

    private func table(_ plan: PlanRows) -> some View {
        Table(review.visible, selection: $selection, sortOrder: $review.sortOrder) {
            TableColumn("Status", value: \.statusRank) { StatusBadge(row: $0) }
                .width(min: 70, ideal: 84, max: 120)
            TableColumn("File", value: \.src) { row in
                HStack(spacing: 6) {
                    Image(systemName: Self.icon(row)).foregroundStyle(.secondary).frame(width: 16)
                    Text(row.src).lineLimit(1).truncationMode(.middle)
                }
                .help(row.src)
            }
            .width(min: 120, ideal: 200)
            TableColumn("Goes to", value: \.dst) { row in
                DestinationText(row: row)
            }
            .width(min: 120, ideal: 220)
            TableColumn("Category", value: \.category) { row in
                Text(row.category).lineLimit(1)
            }
            .width(min: 56, ideal: 84, max: 180)
            TableColumn("Sure", value: \.confidence) { row in
                Text(Self.confidence(row)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 40, ideal: 46, max: 70)
            TableColumn("Size", value: \.size) { row in
                Text(ProgressText.bytes(row.size)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 60, max: 90)
        }
        .contextMenu(forSelectionType: Int.self) { ids in
            RowActions(review: review, ids: ids, quickLook: { quickLook(ids) }, reveal: { reveal(ids) })
        } primaryAction: { _ in
            showInspector = true
        }
        .onKeyPress(.space) {
            quickLook(selection)
            return .handled
        }
        .overlay {
            if review.visible.isEmpty {
                Text(review.search.isEmpty ? "No rows here." : "Nothing matches “\(review.search)”.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func unsavedBar(_ plan: PlanRows) -> some View {
        let n = review.pending.count
        return HStack(spacing: 12) {
            Image(systemName: "pencil.circle.fill").foregroundStyle(.blue).font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(ProgressText.count(n)) unsaved \(n == 1 ? "change" : "changes")").fontWeight(.semibold)
                Text("Save writes them into \((plan.csv as NSString).lastPathComponent), the file Numbers opens.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Discard") { review.discardChanges() }
                .disabled(review.saving)
            Button(review.saving ? "Saving…" : "Save") { Task { await review.save() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s")
                .disabled(review.saving)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func noPlan(_ error: DeweyError) -> some View {
        VStack(spacing: 12) {
            if case .failed(let code, _) = error, code == "no_plan" || code == "no_catalog" {
                Image(systemName: "list.bullet.rectangle").font(.system(size: 40)).foregroundStyle(.secondary)
                Text("No plan yet").font(.title2.bold())
                Text("Scan & Plan suggests where every file goes. Then you review it here.")
                    .foregroundStyle(.secondary)
                ScanPlanButton(folder: folder)
            } else {
                Notice(systemImage: "exclamationmark.triangle.fill", tint: .red, text: error.errorDescription ?? "\(error)") {
                    Button("Try Again") { Task { await review.load() } }
                }
                .frame(maxWidth: 560)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - actions

    private func quickLook(_ ids: Set<Int>) {
        guard let id = ids.min(), let url = review.sourceURL(id) else { return }
        previewURL = previewURL == url ? nil : url
    }

    private func reveal(_ ids: Set<Int>) {
        let urls = ids.sorted().compactMap(review.sourceURL)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    static func icon(_ row: PlanReview.Row) -> String {
        switch row.action {
        case "folder": "folder"
        case "duplicate": "square.on.square"
        default: "doc"
        }
    }

    /// The model's confidence; rules and duplicates are certain by definition, so they show a dash.
    static func confidence(_ row: PlanReview.Row) -> String {
        guard row.confidence >= 0, row.decidedBy.hasPrefix("systemone:") || row.decidedBy.hasPrefix("chat:") else {
            return "–"
        }
        return row.confidence.formatted(.percent.precision(.fractionLength(0)))
    }
}

/// auto / review / skip as a coloured label, with marks for unsaved, changed and refused rows.
/// A row that has moved says "Moved", whatever its status: it isn't waiting for anything.
struct StatusBadge: View {
    let row: PlanReview.Row

    var body: some View {
        let color = row.isMoved ? Color.blue : Self.color(row.status)
        HStack(spacing: 5) {
            Text(row.isMoved ? "Moved" : Self.label(row.status))
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .foregroundStyle(color)
                .background(color.opacity(0.16), in: Capsule())
            if row.verdict == "refused" {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help(row.why)
            }
            if row.pending {
                Circle().fill(.blue).frame(width: 7, height: 7).help("Changed here, not saved yet")
            } else if row.changed {
                Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary).help("Changed from the plan")
            }
        }
    }

    static func label(_ status: String) -> String {
        switch status {
        case "auto": "Move"
        case "review": "Review"
        case "skip": "Skip"
        default: status.isEmpty ? "?" : status
        }
    }

    static func color(_ status: String) -> Color {
        switch status {
        case "auto": .green
        case "review": .orange
        case "skip": .secondary
        default: .red
        }
    }

    static func explanation(_ status: String) -> String {
        switch status {
        case "auto": "Moves when you apply the plan."
        case "review": "Moves only if you include review rows when you apply."
        case "skip": "Stays where it is."
        default: "Not a status dewey knows (auto, review or skip): apply refuses this row."
        }
    }
}

/// The "Goes to" cell.
struct DestinationText: View {
    let row: PlanReview.Row

    var body: some View {
        Group {
            switch row.verdict {
            case "moved":
                Text("moved to \(row.dst)").foregroundStyle(.secondary)
            case "stay" where !row.pending:
                Text("stays where it is").foregroundStyle(.secondary)
            case "noop" where !row.pending:
                Text("already there").foregroundStyle(.secondary)
            default:
                Text(row.dst).italic(row.dstIsPreview)
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .help(row.verdict == "refused" || row.isMoved ? row.why : row.dst)
    }
}

/// Filter chips with counts, and actions for the selected rows.
private struct FilterBar: View {
    @Bindable var review: PlanReview
    @Binding var selection: Set<Int>
    let reveal: (Set<Int>) -> Void

    private static let titles: [PlanReview.Filter: String] = [
        .all: "All", .auto: "Move", .review: "Review", .skip: "Skip", .moved: "Moved", .duplicate: "Duplicates",
        .folder: "Folders", .changed: "Changed", .problems: "Problems",
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(PlanReview.Filter.allCases) { f in
                let n = review.counts[f] ?? 0
                if f == .all || n > 0 || review.filter == f {
                    Button {
                        review.filter = f
                    } label: {
                        HStack(spacing: 4) {
                            Text(Self.titles[f] ?? f.rawValue)
                            Text(ProgressText.count(n)).foregroundStyle(review.filter == f ? .primary : .secondary)
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(review.filter == f ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.1),
                                    in: Capsule())
                        .foregroundStyle(f == .problems ? .red : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 12)
            if !selection.isEmpty {
                Text("\(ProgressText.count(selection.count)) selected").foregroundStyle(.secondary)
                Button("Approve") { review.setStatus("auto", for: selection) }
                    .help("Move these when the plan is applied (status auto)")
                Button("Reject") { review.setStatus("skip", for: selection) }
                    .help("Leave these where they are (status skip)")
                Button {
                    reveal(selection)
                } label: {
                    Image(systemName: "folder")
                }
                .keyboardShortcut("r")
                .help("Show in Finder (⌘R)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// The same actions for one row or many: the context menu, and the inspector for several rows.
struct RowActions: View {
    let review: PlanReview
    let ids: Set<Int>
    let quickLook: () -> Void
    let reveal: () -> Void

    var body: some View {
        if !ids.isEmpty {
            Button("Approve: Move") { review.setStatus("auto", for: ids) }
            Button("Mark for Review") { review.setStatus("review", for: ids) }
            Button("Reject: Skip") { review.setStatus("skip", for: ids) }
            CategoryMenu(review: review, ids: ids)
            Divider()
            Button("Quick Look", action: quickLook)
            Button("Show in Finder", action: reveal)
            Divider()
            if ids.contains(where: { review.pending[$0] != nil }) {
                Button("Undo Unsaved Changes") { review.undoChanges(ids) }
            }
            if ids.contains(where: { review.displayRow($0)?.changed == true }) {
                Button("Revert to Plan") { review.revertToPlan(ids) }
            }
        }
    }
}

struct CategoryMenu: View {
    let review: PlanReview
    let ids: Set<Int>

    var body: some View {
        let first = ids.min() ?? 0
        Menu("Category") {
            ForEach(review.categoryChoices(for: first), id: \.self) { key in
                Button(Self.title(key, review: review, folder: review.row(first)?.action == "folder")) {
                    review.setCategory(key, for: ids)
                }
            }
        }
    }

    static func title(_ key: String, review: PlanReview, folder: Bool) -> String {
        guard let home = review.home(of: key, folder: folder) else { return key }
        return home.isEmpty ? "\(key)  (leave in place)" : "\(key)  →  \(home)"
    }
}
