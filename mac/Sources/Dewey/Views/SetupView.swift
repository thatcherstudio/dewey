import AppKit
import DeweyCore
import SwiftUI

struct ContentView: View {
    var body: some View {
        SetupView()
            .toolbar {
                ToolbarItem(placement: .primaryAction) { LayaStatusView() }
            }
    }
}

/// Green/red checks for everything Dewey needs, each red one with the exact command that fixes it.
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
                CheckRow(title: "laya-serve", check: model.layaServe,
                         fixIntro: "Install it (a few minutes; Laya and its 800 MB model download once):",
                         fix: model.layaFix, chooseTitle: "Choose the laya-serve executable", prefKey: Prefs.layaServePath)
                LayaCheckRow()
                if !model.dewey.isOK || !model.layaServe.isOK {
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
