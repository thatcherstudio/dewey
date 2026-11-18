import DeweyCore
import SwiftUI

/// A move or undo in progress, then what happened: the progress bar, the log, Cancel.
struct JobScreen<Value: Decodable & Sendable, Outcome: View, Actions: View>: View {
    let folder: FolderModel
    let run: CommandRun<Value>
    let title: String
    /// Shown beside Cancel while it runs.
    let activeNote: String
    @ViewBuilder var outcome: Outcome
    /// The footer buttons once it has ended.
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    ForEach(run.progress.phases) { PhaseRow(phase: $0) }
                    outcome
                    LogBox(lines: run.progress.log)
                }
                .padding(28)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            Divider()
            HStack {
                if run.isActive {
                    Text(activeNote).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { run.cancel() }
                        .keyboardShortcut(".", modifiers: .command)
                        .help("Stop after the file in hand (⌘.).")
                } else {
                    actions
                }
            }
            .controlSize(.large)
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.largeTitle.bold())
            if run.isActive {
                TimelineView(.periodic(from: run.startedAt, by: 1)) { ctx in
                    Text("\(folder.displayPath) · \(ProgressText.clock(ctx.date.timeIntervalSince(run.startedAt)))")
                }
                .foregroundStyle(.secondary)
                .monospacedDigit()
            } else {
                let took = (run.endedAt ?? .now).timeIntervalSince(run.startedAt)
                Text("\(folder.displayPath) · took \(ProgressText.clock(took))").foregroundStyle(.secondary)
            }
        }
    }
}

/// Apply's Move: files going into place, then moved / skipped / failed.
struct MoveRunView: View {
    let folder: FolderModel
    let run: CommandRun<ApplyResult>
    @State private var undoRequest: UndoRequest?

    var body: some View {
        JobScreen(folder: folder, run: run, title: title,
                  activeNote: "Each move is logged as it happens, so it can be undone.") {
            outcome
        } actions: {
            if let dest = run.value?.destRoot {
                Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: dest)) }
            }
            Spacer()
            if let batch {
                Button(run.value == nil ? "Undo These Moves…" : "Undo This Batch…") {
                    undoRequest = UndoRequest(batch: batch, what: run.value?.movedText, newerBatch: false)
                }
            }
            Button("Done") { folder.dismissMoves() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .confirmUndo($undoRequest, folder: folder)
    }

    private var batch: String? {
        switch run.state {
        case .finished(let r): r.batch
        case .stopped(let b): b
        case .running, .failed: nil
        }
    }

    private var title: String {
        switch run.state {
        case .running: "Moving files…"
        case .finished(let r): r.counts.moved == 0 ? "Nothing moved" : "Moved \(r.movedText)"
        case .failed: "The move stopped"
        case .stopped: "Stopped"
        }
    }

    /// Refused, skipped and failed lines are plan rows (a whole folder is one row).
    static func rows(_ n: Int) -> String { "\(ProgressText.count(n)) \(n == 1 ? "row" : "rows")" }

    @ViewBuilder
    private var outcome: some View {
        switch run.state {
        case .running:
            EmptyView()
        case .finished(let r):
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Stat(n: r.counts.moved, label: "moved (\(ProgressText.bytes(r.counts.bytesMoved)))", tint: .green)
                    if r.counts.skipped > 0 { Stat(n: r.counts.skipped, label: "skipped", tint: .orange) }
                    if r.counts.failed > 0 { Stat(n: r.counts.failed, label: "failed", tint: .red) }
                    if r.counts.prunedDirs > 0 {
                        Stat(n: r.counts.prunedDirs, label: "empty folders removed", tint: .secondary)
                    }
                }
                if !r.skipped.isEmpty || !r.failed.isEmpty {
                    ProblemList(title: "\(Self.rows(r.skipped.count + r.failed.count)) didn't move",
                                lines: (r.skipped + r.failed).map { ($0.src, $0.text) })
                }
                if r.batch != nil {
                    Notice(systemImage: "arrow.uturn.backward.circle", tint: .blue,
                           text: "Every move is in History. Undo puts \(r.counts.moved == 1 ? "it" : "them all") back "
                                 + "where \(r.counts.moved == 1 ? "it was" : "they were").")
                }
            }
        case .stopped(let batch):
            Notice(systemImage: "stop.circle", tint: .secondary,
                   text: batch == nil
                       ? "Stopped before anything moved."
                       : "Stopped. The files moved so far stay where they are now; Undo puts them back.")
        case .failed(let error):
            Notice(systemImage: "exclamationmark.triangle.fill", tint: .red, text: error.errorDescription ?? "\(error)")
        }
    }
}

/// History's Undo: files going back, then restored / left where they are.
struct UndoRunView: View {
    let folder: FolderModel
    let run: CommandRun<UndoResult>

    var body: some View {
        JobScreen(folder: folder, run: run, title: title,
                  activeNote: "Files go back one at a time; Cancel keeps the ones already back.") {
            outcome
        } actions: {
            Button("Show in Finder") { folder.showInFinder() }
            Spacer()
            if case .stopped = run.state, let batch = run.arguments.last {
                Button("Continue Undo") { folder.undo(batch: batch) }
            }
            Button("Done") { folder.dismissMoves() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var title: String {
        switch run.state {
        case .running: "Putting files back…"
        case .finished(let r):
            r.restored == 0 ? "Nothing went back"
                : r.skipped == 0 ? "Everything is back" : "Put back \(r.restored) of \(r.restored + r.skipped)"
        case .failed: "Undo stopped"
        case .stopped: "Stopped"
        }
    }

    @ViewBuilder
    private var outcome: some View {
        switch run.state {
        case .running:
            EmptyView()
        case .finished(let r):
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Stat(n: r.restored, label: "back where they were", tint: .green)
                    if r.skipped > 0 { Stat(n: r.skipped, label: "left where they are", tint: .orange) }
                    if r.dirsRemoved > 0 { Stat(n: r.dirsRemoved, label: "empty folders removed", tint: .secondary) }
                }
                if !r.skippedItems.isEmpty {
                    ProblemList(title: "\(ProgressText.count(r.skippedItems.count)) "
                                       + "\(r.skippedItems.count == 1 ? "item stayed where it is" : "items stayed where they are")",
                                lines: r.skippedItems.map { (Self.relative($0.path, to: folder.path), $0.why) })
                }
            }
        case .stopped:
            Notice(systemImage: "stop.circle", tint: .secondary,
                   text: "Stopped. The files put back so far are back; Continue Undo puts back the rest.")
        case .failed(let error):
            Notice(systemImage: "exclamationmark.triangle.fill", tint: .red, text: error.errorDescription ?? "\(error)")
        }
    }

    static func relative(_ path: String, to root: String) -> String {
        path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }
}

/// Rows that didn't move or go back, with dewey's reason for each.
struct ProblemList: View {
    let title: String
    let lines: [(path: String, why: String)]
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(lines.indices, id: \.self) { i in
                        (Text(lines[i].path).fontWeight(.medium) + Text(": \(lines[i].why)").foregroundColor(.secondary))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 180)
        } label: {
            Label(title, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }
}

/// "Put back N files?" before an undo.
struct UndoRequest: Identifiable {
    let batch: String
    /// "6 files", "4 files and 2 folders"; nil when not known (a move stopped part way).
    let what: String?
    /// A newer batch still has files out: undoing this one first can leave some where they are.
    let newerBatch: Bool
    var id: String { batch }
}

extension View {
    func confirmUndo(_ request: Binding<UndoRequest?>, folder: FolderModel) -> some View {
        let r = request.wrappedValue
        let what = r?.what ?? "the files moved so far"
        return confirmationDialog("Put back \(what)?",
                                  isPresented: Binding(get: { request.wrappedValue != nil },
                                                       set: { if !$0 { request.wrappedValue = nil } }),
                                  presenting: r) { r in
            Button("Put Back") { folder.undo(batch: r.batch) }
            Button("Cancel", role: .cancel) {}
        } message: { r in
            Text("They go back to where they were before this batch. A file changed since it moved stays where it "
                 + "is now, and folders Dewey made for them are removed if they're empty."
                 + (r.newerBatch ? "\n\nA newer batch hasn't been undone. If it moved the same files, undo it first." : ""))
        }
    }
}
