import DeweyCore
import SwiftUI

/// `dewey status` as cards, with the Scan & Plan button.
struct OverviewView: View {
    let folder: FolderModel
    @State private var confirmNewPlan = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if !folder.exists {
                    Notice(systemImage: "questionmark.folder", tint: .orange,
                           text: "\(folder.displayPath) isn't there. Plug in its disk, or remove it from the sidebar.")
                } else if let error = folder.statusError {
                    Notice(systemImage: "exclamationmark.triangle.fill", tint: .red, text: error) {
                        Button("Try Again") { Task { await folder.refresh() } }
                    }
                }
                if let status = folder.status {
                    if status.catalog {
                        StatusCards(status: status, review: { folder.openReview() },
                                    apply: { folder.tab = .apply }, history: { folder.tab = .history })
                        if !status.errors.isEmpty, let scan = status.scan {
                            ScanErrorsView(errors: status.errors, total: scan.errors ?? status.errors.count)
                        }
                    } else {
                        notScanned
                    }
                } else if folder.loading {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(28)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(folder.name).font(.largeTitle.bold())
                Text(folder.displayPath)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                HStack {
                    Button("Show in Finder") { folder.showInFinder() }
                        .controlSize(.large)
                    Button("Scan & Plan") {
                        if folder.hasUnsavedChanges { confirmNewPlan = true } else { folder.scanAndPlan() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!folder.exists)
                    .confirmationDialog("Make a new plan and drop your unsaved changes?", isPresented: $confirmNewPlan) {
                        Button("Discard Changes and Scan", role: .destructive) {
                            folder.review?.discardChanges()
                            folder.scanAndPlan()
                        }
                        Button("Review Changes") { folder.openReview() }
                    } message: {
                        Text("You changed rows of the current plan in Review and didn't save. A new plan replaces it.")
                    }
                }
                Text("Reads every file. Nothing moves.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var notScanned: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Not scanned yet", systemImage: "sparkle.magnifyingglass")
                .font(.title2.weight(.semibold))
            Text("Scan & Plan reads every file in this folder, finds exact duplicates and suggests where each "
                 + "file belongs. You look over the plan before anything moves, and every move can be undone.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct StatusCards: View {
    let status: FolderStatus
    var review: () -> Void = {}
    var apply: () -> Void = {}
    var history: () -> Void = {}

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16, alignment: .top)], alignment: .leading,
                  spacing: 16) {
            filesCard
            duplicatesCard
            planCard
            movesCard
            if !status.topTypes.isEmpty { typesCard }
        }
    }

    private var filesCard: some View {
        Card(title: "Files", systemImage: "doc.on.doc") {
            let files = status.scan?.files ?? status.count("file")
            Big("\(ProgressText.count(files)) \(files == 1 ? "file" : "files")")
            Text(ProgressText.bytes(status.scan?.bytes ?? 0))
            let units = status.count("bundle") + status.count("project")
            if units > 0 {
                Text("\(ProgressText.count(units)) apps and code projects kept whole").foregroundStyle(.secondary)
            }
            if let date = DeweyDate.parse(status.scan?.finished) {
                Text("Scanned \(date.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var duplicatesCard: some View {
        Card(title: "Duplicates", systemImage: "square.on.square") {
            let d = status.duplicates
            if d.copies == 0 {
                Big("None")
                Text("No file here has an exact copy.").foregroundStyle(.secondary)
            } else {
                Big("\(ProgressText.count(d.copies)) extra \(d.copies == 1 ? "copy" : "copies")")
                Text("\(ProgressText.bytes(d.wasted)) reclaimable")
                Text("\(ProgressText.count(d.groups)) \(d.groups == 1 ? "file has" : "files have") copies")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var planCard: some View {
        Card(title: "Latest plan", systemImage: "list.bullet.rectangle") {
            if let plan = status.latestPlan {
                let s = plan.summary
                Big("Plan \(plan.id)")
                Text("\(ProgressText.count(s.auto.n)) to move · \(ProgressText.count(s.review.n)) to review · "
                     + "\(ProgressText.count(s.skip.n)) unsure")
                if s.folder.n > 0 {
                    Text("\(ProgressText.count(s.folder.n)) whole \(s.folder.n == 1 ? "folder" : "folders") to review")
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    if let date = DeweyDate.parse(plan.created) {
                        Text("Made \(date.formatted(.relative(presentation: .named)))")
                    }
                    if let decider = plan.decider { Text("· \(Self.deciderName(decider))") }
                }
                .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Review", action: review).buttonStyle(.borderedProminent)
                    Button("Apply", action: apply)
                    Button("Open CSV") { FolderModel.open(plan.csv) }.disabled(plan.csv == nil)
                    Button("Report") { FolderModel.open(plan.report) }.disabled(plan.report == nil)
                }
                .controlSize(.small)
            } else {
                Big("No plan yet")
                Text("Scan & Plan makes one.").foregroundStyle(.secondary)
            }
        }
    }

    /// `systemone:english` → "Laya (english)"; `none` → "rules only"; a chat model keeps its name.
    static func deciderName(_ d: String) -> String {
        if d == "none" { return "rules only" }
        if d.hasPrefix("systemone:") { return "Laya (\(d.dropFirst("systemone:".count)))" }
        if d.hasPrefix("chat:") { return String(d.dropFirst("chat:".count)) }
        return d
    }

    private var movesCard: some View {
        Card(title: "Moves", systemImage: "arrow.right.doc.on.clipboard") {
            if let latest = status.batches.first {
                let n = status.batches.count
                Big("\(ProgressText.count(n)) \(n == 1 ? "batch" : "batches")")
                let undone = latest.undone >= latest.moves && latest.moves > 0
                Text("Latest: \(ProgressText.count(latest.moves)) \(latest.moves == 1 ? "file" : "files")"
                     + (undone ? ", undone" : latest.undone > 0 ? ", \(latest.undone) undone" : ""))
                if let date = DeweyDate.parse(latest.movedAt) {
                    Text("Moved \(date.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("History", action: history)
                    if status.undoable != nil {
                        Text("Can be undone").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .controlSize(.small)
            } else {
                Big("Nothing moved yet")
                Text("Files move only when you apply a plan.").foregroundStyle(.secondary)
            }
        }
    }

    private var typesCard: some View {
        Card(title: "Biggest file types", systemImage: "chart.bar") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                ForEach(status.topTypes.prefix(5), id: \.ext) { t in
                    GridRow {
                        Text(t.ext.isEmpty ? "(none)" : t.ext).fontWeight(.medium)
                        Text(ProgressText.bytes(t.bytes)).gridColumnAlignment(.trailing).monospacedDigit()
                        Text("\(ProgressText.count(t.n)) \(t.n == 1 ? "file" : "files")")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
    }
}

/// The number at the top of a card.
private struct Big: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.title2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
    }
}

/// Files a scan couldn't read, collapsed.
struct ScanErrorsView: View {
    let errors: [PathError]
    let total: Int

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(errors, id: \.self) { e in
                    Text("\(e.path): \(e.error)")
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if total > errors.count {
                    Text("… and \(ProgressText.count(total - errors.count)) more").foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)
        } label: {
            Label("\(ProgressText.count(total)) \(total == 1 ? "file" : "files") couldn't be read",
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }
}

/// A one-line message in a tinted box, with optional buttons.
struct Notice<Actions: View>: View {
    let systemImage: String
    let tint: Color
    let text: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(tint).font(.title3)
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            actions
        }
        .padding(12)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

extension Notice where Actions == EmptyView {
    init(systemImage: String, tint: Color, text: String) {
        self.init(systemImage: systemImage, tint: tint, text: text) { EmptyView() }
    }
}
