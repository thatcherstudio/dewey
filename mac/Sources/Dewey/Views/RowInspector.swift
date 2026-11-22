import DeweyCore
import SwiftUI

/// The details pane beside the review table: one row (why, and its status, category and
/// destination to change), several rows (bulk actions), or a summary of the plan.
struct RowInspector: View {
    let review: PlanReview
    @Binding var selection: Set<Int>
    let quickLook: (Set<Int>) -> Void
    let reveal: (Set<Int>) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if selection.count == 1, let id = selection.first, let row = review.displayRow(id),
                   let planned = review.row(id) {
                    OneRow(review: review, row: row, planned: planned,
                           quickLook: { quickLook([id]) }, reveal: { reveal([id]) })
                        .id(id)
                } else if selection.count > 1 {
                    manyRows
                } else if let plan = review.plan {
                    planSummary(plan)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var manyRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(ProgressText.count(selection.count)) rows selected").font(.title3.bold())
            HStack {
                Button("Approve") { review.setStatus("auto", for: selection) }
                Button("Review") { review.setStatus("review", for: selection) }
                Button("Reject") { review.setStatus("skip", for: selection) }
            }
            CategoryMenu(review: review, ids: selection)
                .fixedSize()
            Divider()
            if selection.contains(where: { review.pending[$0] != nil }) {
                Button("Undo Unsaved Changes") { review.undoChanges(selection) }
            }
            if selection.contains(where: { review.displayRow($0)?.changed == true }) {
                Button("Revert to Plan") { review.revertToPlan(selection) }
            }
            Button("Show in Finder") { reveal(selection) }
        }
    }

    private func planSummary(_ plan: PlanRows) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Plan \(plan.planId)").font(.title3.bold())
            if let date = DeweyDate.parse(plan.created) {
                Text("Made \(date.formatted(.relative(presentation: .named)))"
                     + (plan.decider.map { " · \(StatusCards.deciderName($0))" } ?? ""))
                    .foregroundStyle(.secondary)
            }
            Text("Select a row to see why Dewey suggested it, and to change it. Select several to approve or "
                 + "reject them together.")
            Divider()
            LabeledContent("Moves on its own at") {
                Text(plan.autoConfidence.formatted(.percent.precision(.fractionLength(0))) + " sure or more")
            }
            LabeledContent("Asks you to review from") {
                Text(plan.reviewConfidence.formatted(.percent.precision(.fractionLength(0))))
            }
            Text("Below that, a file is skipped: it stays where it is.")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            Button("Open \((plan.csv as NSString).lastPathComponent)") { FolderModel.open(plan.csv) }
            if let report = plan.report { Button("Open Report") { FolderModel.open(report) } }
        }
    }
}

/// One row: what it is, what the plan says, and the controls to change it.
private struct OneRow: View {
    let review: PlanReview
    let row: PlanReview.Row
    let planned: PlanRow
    let quickLook: () -> Void
    let reveal: () -> Void
    @State private var draft = ""
    @FocusState private var editingDst: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: ReviewView.icon(row)).font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name).font(.title3.bold()).textSelection(.enabled)
                    if row.src != row.name {  // where it is, when it isn't at the top of the folder
                        Text(row.src).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Text(ProgressText.bytes(row.size) + (row.isFolder ? ", moves as one folder" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Quick Look", action: quickLook).keyboardShortcut("y")
                Button("Show in Finder", action: reveal)
            }
            .controlSize(.small)

            Divider()

            if row.isMoved {
                Label("Moved. To change where it went, put its batch back in History first.",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.blue).font(.callout)
            }

            VStack(alignment: .leading, spacing: 6) {
                Picker("Status", selection: Binding(get: { row.status },
                                                    set: { review.setStatus($0, for: [row.id]) })) {
                    Text("Move").tag("auto")
                    Text("Review").tag("review")
                    Text("Skip").tag("skip")
                    if !PlanReview.statuses.contains(row.status) { Text(row.status).tag(row.status) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(StatusBadge.explanation(row.status)).font(.callout).foregroundStyle(.secondary)
            }
            .disabled(row.isMoved)

            VStack(alignment: .leading, spacing: 4) {
                Text("Category").font(.headline)
                Picker("Category", selection: Binding(get: { row.category },
                                                      set: { review.setCategory($0, for: [row.id]) })) {
                    ForEach(review.categoryChoices(for: row.id), id: \.self) { key in
                        Text(CategoryMenu.title(key, review: review, folder: row.isFolder)).tag(key)
                    }
                }
                .labelsHidden()
            }
            .disabled(row.isMoved)

            VStack(alignment: .leading, spacing: 4) {
                Text(row.isMoved ? "Is now at" : "Goes to").font(.headline)
                TextField("Folder/name, relative to the destination", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .focused($editingDst)
                    .onSubmit(commit)
                    .onChange(of: editingDst) { _, focused in if !focused { commit() } }
                    .disabled(row.isMoved)
                Text(destinationNote).font(.caption).foregroundStyle(.secondary)
                if row.verdict == "refused" {
                    Label(row.why, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.callout)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Why").font(.headline)
                if !row.reason.isEmpty { Text(row.reason).textSelection(.enabled) }
                LabeledContent("Decided by", value: Self.decider(row.decidedBy))
                if ReviewView.confidence(row) != "–" {
                    LabeledContent("Sure", value: ReviewView.confidence(row))
                }
                if !row.alternatives.isEmpty {
                    LabeledContent("Runners-up", value: row.alternatives)
                }
            }
            .font(.callout)

            if row.changed || row.pending {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("The plan said").font(.headline)
                    Text("\(StatusBadge.label(planned.planned.status)) · \(planned.planned.category)")
                    Text(planned.planned.dst).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack {
                        if row.pending { Button("Undo Unsaved Changes") { review.undoChanges([row.id]) } }
                        if row.changed { Button("Revert to Plan") { review.revertToPlan([row.id]) } }
                    }
                    .controlSize(.small)
                }
            }
        }
        .onAppear { draft = row.dst }
        .onChange(of: row.dst) { _, new in if !editingDst { draft = new } }
    }

    private var destinationNote: String {
        let dest = review.plan.map { ($0.destRoot as NSString).lastPathComponent } ?? "the folder"
        if row.isMoved { return "Inside \(dest)." }
        if row.verdict == "stay" && !row.pending { return "This category leaves it where it is." }
        if row.dstIsPreview { return "Where the new category puts it. Save to confirm the exact path." }
        return "Inside \(dest). End with / to put it into that folder with its own name."
    }

    private func commit() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { draft = row.dst; return }
        if t != row.dst { review.setDestination(t, for: row.id) }
    }

    static func decider(_ d: String) -> String {
        if d.hasPrefix("rule:") { return "rule “\(d.dropFirst(5))”" }
        if d.hasPrefix("systemone:") { return "Laya model" }
        if d.hasPrefix("chat:") { return "language model (\(d.dropFirst(5)))" }
        switch d {
        case "hash": return "exact duplicate (same contents)"
        case "folder-kind": return "what's inside the folder"
        case "": return "–"
        default: return d
        }
    }
}
