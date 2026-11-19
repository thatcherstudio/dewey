import DeweyCore
import SwiftUI

/// Every batch of moves, newest first, each with Undo.
struct HistoryView: View {
    let folder: FolderModel
    @State private var undoRequest: UndoRequest?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("History").font(.largeTitle.bold())
                    Text("Every batch of moves is logged. Undo puts a batch's files back where they were.")
                        .foregroundStyle(.secondary)
                }
                if let error = folder.statusError {
                    Notice(systemImage: "exclamationmark.triangle.fill", tint: .red, text: error)
                }
                let batches = folder.status?.batches ?? []
                if batches.isEmpty {
                    if folder.loading && folder.status == nil {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        empty
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(batches.enumerated()), id: \.element.id) { i, b in
                            if i > 0 { Divider() }
                            BatchRow(folder: folder, batch: b, undo: {
                                undoRequest = UndoRequest(
                                    batch: b.batch,
                                    what: b.undone == 0 ? b.movesText : "the \(ProgressText.count(b.out)) still moved",
                                    newerBatch: batches[..<i].contains { $0.out > 0 },
                                    from: b.destOutside)
                            })
                        }
                    }
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .confirmUndo($undoRequest, folder: folder)
        .task { await folder.refresh() }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Nothing moved yet", systemImage: "clock.arrow.circlepath").font(.title2.weight(.semibold))
            Text("Files move only when you apply a plan. Each time, the moves show up here, ready to undo.")
                .foregroundStyle(.secondary)
            Button("Apply the Plan") { folder.tab = .apply }
                .disabled(folder.status?.latestPlan == nil)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct BatchRow: View {
    let folder: FolderModel
    let batch: FolderStatus.Batch
    let undo: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: batch.out == 0 ? "arrow.uturn.backward.circle" : "arrow.right.circle.fill")
                .font(.title2)
                .foregroundStyle(batch.out == 0 ? Color.secondary : Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text("Moved \(batch.movesText)" + (batch.planId.map { " · Plan \($0)" } ?? ""))
                    .font(.headline)
                if let date = DeweyDate.parse(batch.movedAt) {
                    Text("\(date.formatted(date: .abbreviated, time: .shortened)) "
                         + "(\(date.formatted(.relative(presentation: .named))))")
                        .foregroundStyle(.secondary)
                }
                Text(state).font(.callout).foregroundStyle(batch.out == 0 ? .secondary : .primary)
            }
            Spacer()
            if let log = folder.journal(batch.batch) {
                Button("Log") { NSWorkspace.shared.activateFileViewerSelecting([log]) }
                    .help("Show this batch's log in Finder: every file, where it went and why")
            }
            if batch.out > 0 {
                Button("Undo…", action: undo)
                    .disabled(folder.isRunning)
                    .help("Put this batch's files back where they were")
            }
        }
        .padding(14)
    }

    private var state: String {
        if batch.out == 0 { return "Undone: everything went back" }
        if batch.undone > 0 { return "\(ProgressText.count(batch.undone)) of \(ProgressText.count(batch.moves)) put back" }
        return "Can be undone"
    }
}
