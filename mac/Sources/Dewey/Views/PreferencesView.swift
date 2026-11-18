import SwiftUI

/// Dewey > Settings… (⌘,): where the tools are and how Laya runs.
struct PreferencesView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.deweyPath) private var deweyPath = ""
    @AppStorage(Prefs.layaServePath) private var layaServePath = ""
    @AppStorage(Prefs.layaURL) private var layaURL = Prefs.defaultLayaURL
    @AppStorage(Prefs.startLayaOnLaunch) private var startLaya = true

    var body: some View {
        Form {
            Section {
                PathRow(title: "dewey", path: $deweyPath) {
                    model.choose(Prefs.deweyPath, title: "Choose the dewey executable")
                }
                PathRow(title: "laya-serve", path: $layaServePath) {
                    model.choose(Prefs.layaServePath, title: "Choose the laya-serve executable")
                }
            } header: {
                Text("Tools")
            } footer: {
                Text("Leave empty to find them automatically (~/.venvs, ~/.local/bin, Homebrew, your shell's PATH).")
            }
            Section("Laya model") {
                TextField("URL", text: $layaURL)
                Toggle("Start Laya when Dewey opens", isOn: $startLaya)
            }
            HStack {
                Spacer()
                Button("Check Again") { Task { await model.checkAll() } }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PathRow: View {
    let title: String
    @Binding var path: String
    let choose: () -> Void

    var body: some View {
        HStack {
            TextField(title, text: $path, prompt: Text("found automatically"))
            Button("Choose…", action: choose)
        }
    }
}
