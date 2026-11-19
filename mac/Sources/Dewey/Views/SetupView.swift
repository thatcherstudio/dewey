import AppKit
import DeweyCore
import SwiftUI

/// Green/red checks for everything Dewey needs, each red one with what fixes it: an Install Laya
/// button for Laya, the exact Terminal commands otherwise.
struct SetupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.everythingReady ? "Dewey is ready" : "Set up Dewey")
                        .font(.largeTitle.bold())
                    Text("Dewey runs the dewey command-line tool and the Laya decision model on this Mac. "
                         + "Nothing leaves the Mac.")
                        .foregroundStyle(.secondary)
                }
                CheckRow(title: "dewey", check: model.dewey, fixIntro: "Install it (about 1 minute):",
                         fix: model.deweyFix, chooseTitle: "Choose the dewey executable", prefKey: Prefs.deweyPath)
                LayaServeRow()
                LayaCheckRow()
                if !model.dewey.isOK {
                    Text("No `uv`? Install it with `\(SetupCommands.installUV)`, then run the commands above in Terminal.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Button("Check Again") { Task { await model.checkAll() } }
                    .keyboardShortcut("r")
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

struct StatusIcon: View {
    enum Kind { case ok, problem, busy, idle }
    let kind: Kind

    var body: some View {
        Group {
            switch kind {
            case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .problem: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            case .busy: ProgressView().controlSize(.small)
            case .idle: Image(systemName: "pause.circle.fill").foregroundStyle(.secondary)
            }
        }
        .font(.title2)
        .frame(width: 28)
    }
}

struct CheckRow: View {
    @Environment(AppModel.self) private var model
    let title: String
    let check: AppModel.Check
    let fixIntro: String
    let fix: String
    let chooseTitle: String
    let prefKey: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            switch check {
            case .checking: StatusIcon(kind: .busy)
            case .ok: StatusIcon(kind: .ok)
            case .problem: StatusIcon(kind: .problem)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                switch check {
                case .checking:
                    Text("Checking…").foregroundStyle(.secondary)
                case .ok(let detail):
                    Text(detail).foregroundStyle(.secondary).textSelection(.enabled)
                case .problem(let why):
                    Text(why).textSelection(.enabled)
                    Text(fixIntro).font(.callout)
                    CommandBox(command: fix)
                    Button("Choose \(title)…") { model.choose(prefKey, title: chooseTitle) }
                        .help("Already installed somewhere else? Point Dewey at it.")
                }
            }
        }
    }
}

/// laya-serve: found (with Remove Laya… when Install Laya set it up), or an Install Laya button
/// (with the Terminal commands as the other way).
struct LayaServeRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let installer = model.installer
        HStack(alignment: .top, spacing: 12) {
            switch model.layaServe {
            case _ where installer.isRunning || installer.isRemoving: StatusIcon(kind: .busy)
            case .checking: StatusIcon(kind: .busy)
            case .ok: StatusIcon(kind: .ok)
            case .problem: StatusIcon(kind: .problem)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("laya-serve").font(.headline)
                if let why = model.layaRemoveError {
                    Label(why, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if installer.isRunning {
                    LayaInstallProgress(installer: installer)
                } else if installer.isRemoving {
                    Text("Removing Laya…").foregroundStyle(.secondary)
                } else {
                    switch model.layaServe {
                    case .checking:
                        Text("Checking…").foregroundStyle(.secondary)
                    case .ok(let detail):
                        Text(detail).foregroundStyle(.secondary).textSelection(.enabled)
                        if model.layaInstallBytes > 0 { LayaRemoveButton() }
                    case .problem(let why):
                        Text(why).textSelection(.enabled)
                        LayaInstallOffer(installer: installer)
                    }
                }
            }
        }
    }
}

/// Remove Laya… for the laya-serve Install Laya set up, or Delete Downloaded Files… for what an
/// install that didn't finish (or isn't the one in use) left behind. Both ask first.
struct LayaRemoveButton: View {
    @Environment(AppModel.self) private var model
    @State private var confirm = false

    var body: some View {
        let inUse = model.layaInstalledByDewey
        let size = LayaInstaller.size(model.layaInstallBytes)
        let place = (model.installer.layout.root.path as NSString).abbreviatingWithTildeInPath
        let busy = !model.busyFolders.isEmpty
        Button(inUse ? "Remove Laya…" : "Delete Downloaded Files (\(size))…") { confirm = true }
            .disabled(busy)
            .help(busy ? "Wait until Dewey is done with your folders." : "Frees \(size) in \(place).")
            .confirmationDialog(inUse ? "Remove Laya?" : "Delete what Install Laya downloaded?",
                                isPresented: $confirm) {
                Button(inUse ? "Remove" : "Delete", role: .destructive) { Task { await model.removeLaya() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(inUse
                     ? "Stops Laya, then deletes Python, Laya and its model from \(place), freeing \(size). "
                       + "Until you install it again, plans use your rules and duplicates only."
                     : "Frees \(size) in \(place). Installing Laya again then starts from the beginning.")
            }
    }
}

/// The Install Laya button, what it does, how the last try ended, and the other ways in.
struct LayaInstallOffer: View {
    @Environment(AppModel.self) private var model
    let installer: LayaInstaller

    private var retry: Bool {
        switch installer.state {
        case .failed, .cancelled: true
        default: false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch installer.state {
            case .failed(let why):
                Label(why, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                if installer.fraction > 0 {
                    Text("What it downloaded is kept, so trying again picks up from there.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !installer.log.isEmpty { InstallLog(lines: installer.log) }
            case .cancelled:
                Text("Install stopped. What it downloaded is kept, so installing again picks up from there.")
                    .font(.callout).foregroundStyle(.secondary)
            default:
                EmptyView()
            }
            HStack {
                Button(retry ? "Try Again" : "Install Laya") {
                    Task { await model.installLaya() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.uvURL == nil)
                Button("Choose laya-serve…") {
                    model.choose(Prefs.layaServePath, title: "Choose the laya-serve executable")
                }
                .help("Already installed somewhere else? Point Dewey at it.")
            }
            Text("Downloads Python, Laya, PyTorch and Laya's English model, about 1.7 GB in all, into "
                 + "\((installer.layout.root.path as NSString).abbreviatingWithTildeInPath). Takes 5 to 15 minutes, "
                 + "depending on your connection. Dewey starts Laya when it's done.")
                .font(.callout).foregroundStyle(.secondary)
            if model.uvURL == nil {
                Text("This Dewey has no uv inside it to install with. Build it with `make app`, or install uv "
                     + "(`\(SetupCommands.installUV)`) and click Check Again.")
                    .font(.callout)
                    .textSelection(.enabled)
            }
            if model.layaInstallBytes > 0 { LayaRemoveButton() }
            DisclosureGroup("Or install it in Terminal") {
                VStack(alignment: .leading, spacing: 8) {
                    CommandBox(command: model.layaFix)
                    Text("No `uv`? Install it with `\(SetupCommands.installUV)` first. Then click Check Again.")
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .padding(.top, 4)
            }
            .font(.callout)
        }
    }
}

/// The bar, the step, the bytes, the time so far, and Cancel.
struct LayaInstallProgress: View {
    let installer: LayaInstaller

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: installer.fraction)
                .frame(maxWidth: 420)
            if case .running(let step) = installer.state {
                Text("Step \(step.rawValue + 1) of \(LayaInstaller.Step.allCases.count): \(step.title)")
                Text(bytes(step))
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(spacing: 12) {
                Button("Cancel") { installer.cancel() }
                if let since = installer.startedAt {
                    TimelineView(.periodic(from: since, by: 1)) { ctx in
                        Text("\(LayaPanel.clock(ctx.date.timeIntervalSince(since))) so far; usually 5 to 15 minutes")
                            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            if !installer.log.isEmpty { InstallLog(lines: installer.log) }
        }
    }

    private func bytes(_ step: LayaInstaller.Step) -> String {
        let done = LayaInstaller.size(installer.stepBytes)
        switch (step, installer.stepTotal) {
        case (.model, let total?): return "\(done) of \(LayaInstaller.size(total)) downloaded"
        case (.model, nil): return "Asking Hugging Face for the model…"
        case (_, let total?): return "\(done) of about \(LayaInstaller.size(total))"
        case (_, nil): return done
        }
    }
}

struct InstallLog: View {
    let lines: [String]

    var body: some View {
        DisclosureGroup("Log (last \(lines.count) lines)") {
            ScrollView {
                Text(lines.suffix(80).joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 140)
        }
        .font(.callout)
    }
}

struct LayaCheckRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            switch model.laya.status {
            case .ready: StatusIcon(kind: .ok)
            case .failed: StatusIcon(kind: .problem)
            case .starting, .unknown: StatusIcon(kind: .busy)
            case .stopped: StatusIcon(kind: .idle)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Laya model").font(.headline)
                LayaPanel(showLog: false)
            }
        }
    }
}

/// A command to paste into Terminal, with a Copy button.
struct CommandBox: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }
}
