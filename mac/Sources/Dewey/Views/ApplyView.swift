import DeweyCore
import SwiftUI

/// The Apply tab: made the first time it opens, then kept with the folder.
struct ApplyTab: View {
    let folder: FolderModel

    var body: some View {
        Group {
            if let apply = folder.apply {
                ApplyView(folder: folder, apply: apply)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { folder.makeApply() }
    }
}

/// Preview (a dry run: every row that will move, every row refused and why), then Move.
struct ApplyView: View {
    let folder: FolderModel
    @Bindable var apply: ApplyPlan
    @State private var confirmMove = false
    @State private var sortOrder = [KeyPathComparator(\ApplyPreview.Item.row)]
    @State private var selection = Set<Int>()
    @State private var saving = false

    /// What the preview depends on: a new one when any of it changes.
    private struct Key: Equatable {
        var includeReview: Bool
        var planId: Int?
        var csvSha: String?
    }

    private var key: Key {
        Key(includeReview: apply.includeReview, planId: folder.status?.latestPlan?.id,
            csvSha: folder.review?.plan?.csvSha256)
    }

    var body: some View {
        VStack(spacing: 0) {
            top
                // Not in a scroll view: wrapped text measured at zero width (for the window's minimum
                // size) would claim one character per line and push the whole window off screen.
                .frame(minWidth: 480, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)
            content
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .task(id: key) { await apply.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await apply.refresh() }  // plan-N.csv may have been saved from Numbers
        }
        .confirmationDialog(moveQuestion, isPresented: $confirmMove) {
            Button("Move") { folder.startMove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(moveDetail)
        }
    }

    // MARK: - top

    private var top: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(apply.preview.map { "Apply Plan \($0.planId)" } ?? "Apply").font(.title2.bold())
                    Text("Moves the rows marked Move into place. Every move is logged and can be undone in History.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Also move rows marked Review", isOn: $apply.includeReview)
                        .help("Without this, only rows marked Move (auto) move; Review rows stay until you approve them.")
                    Toggle("Remove folders left empty", isOn: $apply.pruneEmpty)
                        .help("Folders the moves empty are removed (one holding only .DS_Store counts as empty). "
                              + "Undo puts them back.")
                }
                .disabled(folder.isRunning)
            }
            if folder.hasUnsavedChanges {
                Notice(systemImage: "pencil.circle", tint: .orange,
                       text: "Review has unsaved changes. Apply moves what the plan file says, so save them first. "
                             + "This preview doesn't include them.") {
                    Button("Save Changes") {
                        saving = true
                        Task {
                            _ = await folder.review?.save()
                            saving = false
                        }
                    }
                    .disabled(saving)
                    Button("Review") { folder.openReview() }
                }
            }
            if let error = apply.error {
                if case .failed(let code, _) = error, code == "no_plan" || code == "no_catalog" {
                    Notice(systemImage: "list.bullet.rectangle", tint: .secondary,
                           text: "No plan yet. Scan & Plan makes one; you review it, then apply it here.") {
                        Button("Go to Overview") { folder.tab = .overview }
                    }
                } else {
                    Notice(systemImage: "exclamationmark.triangle.fill", tint: .red,
                           text: error.errorDescription ?? "\(error)") {
                        Button("Try Again") { Task { await apply.refresh() } }
                    }
                }
            }
            if let p = apply.preview {
                if let dest = p.leavesFolderFor {
                    Notice(systemImage: "arrow.up.forward.square", tint: .orange,
                           text: "This plan files things into \(dest), outside this folder (Organize into, in Settings).")
                }
                summary(p)
                if !p.refused.isEmpty { refused(p) }
            }
        }
    }

    private func summary(_ p: ApplyPreview) -> some View {
        HStack(spacing: 12) {
            Stat(n: p.files, label: p.files == 1 ? "file to move" : "files to move", tint: .green)
            if p.folders > 0 { Stat(n: p.folders, label: "whole folders", tint: .blue) }
            VStack(alignment: .leading, spacing: 2) {
                Text(ProgressText.bytes(p.bytes)).font(.title.weight(.semibold)).monospacedDigit()
                Text("in all").font(.callout).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(minWidth: 110, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            if !p.refused.isEmpty { Stat(n: p.refused.count, label: "refused", tint: .red) }
            if let moved = p.alreadyMoved, moved > 0 { Stat(n: moved, label: "moved already", tint: .blue) }
            Spacer()
        }
        .opacity(apply.isStale ? 0.4 : 1)
    }

    private func refused(_ p: ApplyPreview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProblemList(title: "\(MoveRunView.rows(p.refused.count)) won't move: fix \(p.refused.count == 1 ? "it" : "them") in Review",
                        lines: p.refused.map { ($0.src, $0.why) })
            Button("Show in Review") {
                folder.makeReview()
                folder.review?.filter = .problems
                folder.openReview()
            }
            .controlSize(.small)
        }
    }

    // MARK: - the rows that will move

    @ViewBuilder
    private var content: some View {
        if let p = apply.preview, !p.selected.isEmpty {
            Table(p.selected.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Status", value: \.statusRank) { item in
                    Text(StatusBadge.label(item.status))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .foregroundStyle(StatusBadge.color(item.status))
                        .background(StatusBadge.color(item.status).opacity(0.16), in: Capsule())
                }
                .width(min: 64, ideal: 72, max: 90)
                TableColumn("File", value: \.src) { item in
                    Label(item.src, systemImage: item.isFolder ? "folder" : "doc")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.src)
                }
                .width(min: 160, ideal: 320)
                TableColumn("Goes to", value: \.dst) { item in
                    Text(item.dst).lineLimit(1).truncationMode(.middle).help(item.reason ?? item.dst)
                }
                .width(min: 160, ideal: 360)
                TableColumn("Size", value: \.size) { item in
                    Text(ProgressText.bytes(item.size)).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 80, max: 110)
            }
            .contextMenu(forSelectionType: Int.self) { ids in
                Button("Show in Finder") { reveal(ids, in: p) }
            }
            .opacity(apply.isStale ? 0.4 : 1)
        } else if let p = apply.preview, apply.hasMoved {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(.green)
                Text("This plan has been applied").font(.title2.bold())
                Text(appliedDetail(p.alreadyMoved ?? 0))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                HStack {
                    Button("History") { folder.tab = .history }
                    Button("Review Plan") { folder.openReview() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let p = apply.preview {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle").font(.system(size: 40)).foregroundStyle(.secondary)
                Text("Nothing to move").font(.title2.bold())
                Text(p.refused.isEmpty
                     ? "No row is marked Move. Approve rows in Review" + (apply.includeReview ? "." : ", or turn on "
                         + "“Also move rows marked Review”.")
                     : "The rows marked Move were refused (see above).")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Review Plan") { folder.openReview() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if apply.loading {
            ProgressView("Checking the plan…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear
        }
    }

    /// What the applied plan's screen says under its title. Built a sentence at a time, like `moveDetail`.
    private func appliedDetail(_ n: Int) -> String {
        var text = "\(MoveRunView.rows(n)) moved, and none is left to move."
        text += n == 1 ? " History puts it back." : " History puts them back."
        text += " Rows marked Review or Skip stay until you approve them."
        return text
    }

    private func reveal(_ ids: Set<Int>, in p: ApplyPreview) {
        let root = URL(fileURLWithPath: folder.path)
        let urls = p.selected.filter { ids.contains($0.row) }.map { root.appending(path: $0.src) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    // MARK: - footer

    private var footer: some View {
        HStack {
            if apply.loading {
                ProgressView().controlSize(.small)
                Text("Checking the plan…").foregroundStyle(.secondary)
            } else if (apply.preview?.alreadyMoved ?? 0) > 0 {
                Text("Preview only. What this plan moved before is in History.").foregroundStyle(.secondary)
            } else {
                Text("Preview only: nothing has moved yet.").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh") { Task { await apply.refresh() } }
                .help("Read the plan file again (after editing it in Numbers)")
                .disabled(apply.loading)
            if !apply.hasMoved {  // an applied plan has nothing to move: no Move button to press twice
                Button(moveTitle) { confirmMove = true }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!apply.canMove || folder.hasUnsavedChanges || folder.isRunning)
            }
        }
        .controlSize(.large)
    }

    private var reviewCount: Int { apply.preview?.count(status: "review") ?? 0 }

    private var what: String {
        guard let p = apply.preview else { return "files" }
        return ProgressText.items(files: p.files, folders: p.folders)
    }

    /// Title case, as Mac buttons are: "Move 4 Files and 2 Folders…".
    private var moveTitle: String {
        guard apply.canMove else { return "Move Files…" }
        return "Move " + what.replacingOccurrences(of: "file", with: "File").replacingOccurrences(of: "folder", with: "Folder") + "…"
    }

    private var moveQuestion: String {
        "Move \(what) (\(ProgressText.bytes(apply.preview?.bytes ?? 0)))?"
    }

    /// What the Move question says under its title. Built a sentence at a time: one long joined
    /// expression is more than Xcode 26's compiler will type-check.
    private var moveDetail: String {
        var text = "Each move is logged as it happens. If anything looks wrong afterwards, History puts them all back."
        if let dest = apply.preview?.leavesFolderFor {
            text += "\n\nThey go to \(dest), outside this folder."
        }
        if apply.previewIncludesReview && reviewCount > 0 {
            let rows = reviewCount == 1 ? "row" : "rows"
            text += "\n\nIncludes \(ProgressText.count(reviewCount)) \(rows) still marked Review."
        }
        return text
    }
}
