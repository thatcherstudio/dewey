import DeweyCore
import SwiftUI

/// Toolbar light for the Laya model: grey stopped, orange loading, green ready, red failed.
struct LayaStatusView: View {
    @Environment(AppModel.self) private var model
    @State private var showPanel = false

    var body: some View {
        Button {
            showPanel.toggle()
        } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 9, height: 9)
                Text(label)
            }
        }
        .help("The Laya decision model. Click for Start, Stop and its log.")
        .popover(isPresented: $showPanel, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Laya model").font(.headline)
                LayaPanel(showLog: true)
            }
            .padding(16)
            .frame(width: 460)
        }
    }

    private var color: Color {
        switch model.laya.status {
        case .ready: .green
        case .starting: .orange
        case .failed: .red
        case .stopped, .unknown: .secondary
        }
    }

    private var label: String {
        switch model.laya.status {
        case .ready: "Laya ready"
        case .starting: "Laya loading"
        case .failed: "Laya failed"
        case .stopped: "Laya stopped"
        case .unknown: "Laya"
        }
    }
}

/// What the Laya model is doing, with Start / Stop, used in the setup screen and the toolbar popover.
struct LayaPanel: View {
    @Environment(AppModel.self) private var model
    let showLog: Bool

    var body: some View {
        let laya = model.laya
        VStack(alignment: .leading, spacing: 8) {
            switch laya.status {
            case .unknown:
                Text("Checking…").foregroundStyle(.secondary)
            case .stopped:
                Text(model.layaServeURL == nil
                     ? "Not running. Without it, plans use your rules and duplicates only."
                     : "Not running. Scan & Plan starts it for a folder whose plans ask it.")
                    .foregroundStyle(.secondary)
            case .starting(let since):
                TimelineView(.periodic(from: since, by: 1)) { ctx in
                    Text("Loading the model… \(Self.clock(ctx.date.timeIntervalSince(since)))")
                }
                Text("Usually under a minute; the first start downloads the model.")
                    .font(.callout).foregroundStyle(.secondary)
            case .ready(let h):
                Text("Ready on \(h.device ?? "this Mac")"
                     + (h.loaded.isEmpty ? "" : " (\(h.loaded.joined(separator: ", ")))")
                     + " at \(laya.baseURL.absoluteString)")
                    .textSelection(.enabled)
                if !laya.ownsServer {
                    Text("Started outside Dewey, so Dewey uses it but won't stop it.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            case .failed(let why):
                Text(why).textSelection(.enabled)
            }
            HStack {
                if laya.isRunning {
                    Button("Stop") { laya.stop() }
                } else if case .ready = laya.status {
                    EmptyView()
                } else if !laya.isLocal {  // a Laya on another machine: watched from here, started there
                    Button("Check Again") { Task { await laya.refresh() } }
                } else {
                    Button("Start") { Task { await model.startLaya() } }
                        .disabled(model.layaServeURL == nil)
                        .help(model.layaServeURL == nil ? "Install Laya first: Setup, in the sidebar." : "")
                }
            }
            if showLog || isFailed, !laya.log.isEmpty {
                DisclosureGroup("Log (last \(laya.log.count) lines)") {
                    ScrollView {
                        Text(laya.log.suffix(80).joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 160)
                }
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = model.laya.status { return true }
        return false
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
