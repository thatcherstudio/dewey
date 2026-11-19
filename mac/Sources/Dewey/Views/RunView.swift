import DeweyCore
import SwiftUI

/// Scan & Plan in progress: one bar per phase, the log, Cancel; then the outcome.
struct RunView: View {
    @Environment(AppModel.self) private var model
    let folder: FolderModel
    let session: ScanPlanSession

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(session.progress.phases) { PhaseRow(phase: $0) }
                    }
                    if case .waitingForModel(let since) = session.state {
                        WaitingForModelRow(since: since)
                    }
                    outcome
                    LogBox(lines: session.progress.log)
                }
                .padding(28)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            Divider()
            footer
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
        }
    }

    // MARK: - header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.largeTitle.bold())
            if session.isActive {
                TimelineView(.periodic(from: session.startedAt, by: 1)) { ctx in
                    Text("\(folder.displayPath) · \(ProgressText.clock(ctx.date.timeIntervalSince(session.startedAt)))")
                }
                .foregroundStyle(.secondary)
                .monospacedDigit()
            } else {
                let took = (session.endedAt ?? .now).timeIntervalSince(session.startedAt)
                Text("\(folder.displayPath) · took \(ProgressText.clock(took))")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var title: String {
        switch session.state {
        case .running(.scan): "Scanning \(folder.name)…"
        case .running(.plan): "Planning…"
        case .waitingForModel: "Waiting for the model…"
        case .finished: "Plan \(session.plan?.planId ?? 0) is ready"
        case .failed(.scan, _): "The scan stopped"
        case .failed(.plan, _) where session.remoteServerQuestion != nil: "One question before planning"
        case .failed(.plan, _): "The plan couldn't be made"
        case .stopped: "Stopped"
        }
    }

    // MARK: - outcome

    @ViewBuilder
    private var outcome: some View {
        switch session.state {
        case .running, .waitingForModel:
            EmptyView()
        case .finished:
            if let plan = session.plan {
                PlanOutcome(plan: plan, scan: session.scan, rulesOnly: session.rulesOnly)
            }
        case .stopped:
            VStack(alignment: .leading, spacing: 12) {
                Notice(systemImage: "stop.circle", tint: .secondary,
                       text: "Stopped. Everything finished so far is saved, so the next run picks up from here.")
                if session.scan != nil {  // stopped while planning: no need to scan again
                    Button("Continue Planning") { session.retryPlan(rulesOnly: session.rulesOnly) }
                        .buttonStyle(.borderedProminent)
                }
            }
        case .failed(let step, let error):
            failure(step, error)
        }
    }

    @ViewBuilder
    private func failure(_ step: ScanPlanSession.Step, _ error: DeweyError) -> some View {
        let layaCanStart: Bool = {
            guard model.layaServeURL != nil, !model.laya.isRunning else { return false }
            if case .ready = model.laya.status { return false }
            return true
        }()
        VStack(alignment: .leading, spacing: 12) {
            if let question = session.remoteServerQuestion {
                Notice(systemImage: "network", tint: .orange,
                       text: "The scan is done, and nothing has been sent anywhere. \(question) "
                             + "Allow it only if you set that up yourself.")
                HStack {
                    Button("Allow and Plan") { session.retryPlan(rulesOnly: false, allowRemote: true) }
                        .help("Dewey remembers this for this folder and this server.")
                    Button("Plan with Rules Only") { session.retryPlan(rulesOnly: true) }
                        .help("Plan with your rules and duplicates; nothing leaves this Mac.")
                }
            } else if session.needsModel {
                Notice(systemImage: "brain", tint: .orange,
                       text: "The scan is done, but the decision model didn't answer, so no plan was made. "
                             + "Start it and try again, or plan with your rules only.")
                HStack {
                    if layaCanStart {
                        Button("Start Laya and Try Again") { Task { await folder.startModelAndRetry() } }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Try Again") { session.retryPlan(rulesOnly: false) }
                    }
                    Button("Plan with Rules Only") { session.retryPlan(rulesOnly: true) }
                        .help("Plan with your rules and duplicates; files the rules don't cover stay where they are.")
                }
                // dewey's own words (which model, which URL) are in the log; Laya's own failure is here
                if case .failed(let why) = model.laya.status {
                    Text("Laya: \(why)").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } else {
                Notice(systemImage: "exclamationmark.triangle.fill", tint: .red,
                       text: error.errorDescription ?? "\(error)")
                Button("Try Again") {
                    if step == .plan { session.retryPlan(rulesOnly: session.rulesOnly) } else { session.restart() }
                }
            }
        }
    }

    // MARK: - footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            if session.isActive {
                Text("Nothing moves during Scan & Plan.").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { session.cancel() }
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Stop after the file in hand (⌘.). Work done so far is kept.")
            } else {
                if case .finished = session.state, let plan = session.plan {
                    Button("Open Plan CSV") { FolderModel.open(plan.csv) }
                        .help("The plan as a spreadsheet: change status to auto, review or skip, or edit dst.")
                    Button("Open Report") { FolderModel.open(plan.report) }
                }
                Spacer()
                Button("Scan Again") { session.restart() }
                if case .finished = session.state {
                    Button("Done") { folder.dismissRun() }
                    Button("Review Plan") { folder.openReview() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") { folder.dismissRun() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .controlSize(.large)
    }
}

/// One phase: name, bar, numbers.
struct PhaseRow: View {
    let phase: RunProgress.Phase

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon.font(.title3).frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(phase.label).font(.headline)
                    Text(Self.caption[phase.id] ?? "").foregroundStyle(.secondary)
                    Spacer()
                    if case .running(let p) = phase.state, let f = p.fraction {
                        Text(f.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                    }
                }
                bar
                Text(ProgressText.detail(phase))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .opacity(isIdle ? 0.55 : 1)
    }

    static let caption = ["walk": "finding every file", "hash": "reading and fingerprinting",
                          "decide": "asking the model where files go", "move": "into their new folders",
                          "undo": "back where they were"]

    private var isIdle: Bool {
        switch phase.state {
        case .waiting, .skipped: true
        default: false
        }
    }

    @ViewBuilder
    private var bar: some View {
        if case .running(let p) = phase.state, p.fraction == nil {
            ProgressView().progressViewStyle(.linear)  // walking: no total to measure against
        } else {
            ProgressView(value: phase.fraction ?? 0)
                .tint(isStopped ? .orange : nil)
        }
    }

    private var isStopped: Bool {
        if case .stopped = phase.state { return true }
        return false
    }

    @ViewBuilder
    private var icon: some View {
        switch phase.state {
        case .waiting: Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .stopped: Image(systemName: "stop.circle.fill").foregroundStyle(.orange)
        }
    }
}

struct WaitingForModelRow: View {
    let since: Date

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small).frame(width: 24)
            TimelineView(.periodic(from: since, by: 1)) { ctx in
                Text("The Laya model is still loading (\(ProgressText.clock(ctx.date.timeIntervalSince(since)))). "
                     + "Planning starts as soon as it's ready.")
            }
            .monospacedDigit()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// What the new plan says, in numbers.
struct PlanOutcome: View {
    let plan: PlanResult
    let scan: ScanResult?
    let rulesOnly: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Stat(n: plan.summary.auto.n, label: "to move", tint: .green)
                Stat(n: plan.summary.review.n, label: "to review", tint: .orange)
                Stat(n: plan.summary.skip.n, label: "unsure, left in place", tint: .secondary)
                if plan.summary.folder.n > 0 {
                    Stat(n: plan.summary.folder.n, label: "whole folders to review", tint: .blue)
                }
            }
            if plan.summary.duplicate.n > 0 {
                Text("Includes \(ProgressText.count(plan.summary.duplicate.n)) exact duplicates "
                     + "(\(ProgressText.bytes(plan.summary.duplicate.bytes))), set aside in _Review/Duplicates.")
            }
            if let scan {
                Text(scanLine(scan)).foregroundStyle(.secondary)
                if !scan.errorItems.isEmpty {
                    ScanErrorsView(errors: scan.errorItems, total: scan.errors)
                }
            }
            if rulesOnly {
                Text("Made with rules only: files your rules don't cover stay where they are.")
                    .foregroundStyle(.secondary)
            }
            Notice(systemImage: "hand.raised", tint: .blue,
                   text: "Nothing has moved yet. Review the plan: approve, reject or redirect rows, then apply it.")
        }
    }

    private func scanLine(_ s: ScanResult) -> String {
        var parts = ["Scanned \(ProgressText.count(s.files)) files (\(ProgressText.bytes(s.bytes)))",
                     "read \(ProgressText.count(s.hashed)) new or changed",
                     "reused \(ProgressText.count(s.reused))"]
        if s.cloud > 0 { parts.append("\(ProgressText.count(s.cloud)) in iCloud only, skipped") }
        if s.missing > 0 { parts.append("\(ProgressText.count(s.missing)) gone since last time") }
        return parts.joined(separator: " · ")
    }
}

struct Stat: View {
    let n: Int
    let label: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ProgressText.count(n)).font(.title.weight(.semibold)).monospacedDigit()
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(minWidth: 110, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// dewey's log lines, newest at the bottom, following along as they arrive.
struct LogBox: View {
    let lines: [String]
    @State private var expanded = true

    var body: some View {
        DisclosureGroup("Log", isExpanded: $expanded) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(lines.isEmpty ? " " : lines.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(8)
                }
                .frame(height: 150)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                .onChange(of: lines) { proxy.scrollTo("end", anchor: .bottom) }  // not .count: it stops growing at the cap
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }
}
