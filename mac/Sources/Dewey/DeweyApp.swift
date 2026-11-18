import AppKit
import SwiftUI

@main
struct DeweyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Dewey", id: "main") {
            ContentView()
                .environment(delegate.model)
                .frame(minWidth: 780, minHeight: 520)
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Folder…") { delegate.model.chooseFolders() }
                    .keyboardShortcut("o")
            }
        }
        Settings {
            PreferencesView()
                .environment(delegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)  // a Dock icon and menus even when run with `swift run`
        NSApp.activate()
        Task { await model.launch() }
    }

    /// A scan in progress is safe to stop (it keeps what's done), but say so before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let unsaved = model.foldersWithUnsavedChanges
        if !unsaved.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Quit without saving your changes to the plan?"
            alert.informativeText = "Review has unsaved changes for "
                + unsaved.map(\.name).joined(separator: ", ") + ". Quitting drops them; the plan stays as it was."
            alert.addButton(withTitle: "Keep Reviewing")
            alert.addButton(withTitle: "Quit Anyway")
            guard alert.runModal() == .alertSecondButtonReturn else {
                if let f = unsaved.first { model.selection = .folder(f.path); f.openReview() }
                return .terminateCancel
            }
        }
        let busy = model.busyFolders
        guard !busy.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = busy.count == 1
            ? "Stop Scan & Plan of \(busy[0].name) and quit?"
            : "Stop Scan & Plan of \(busy.count) folders and quit?"
        alert.informativeText = "Everything finished so far is saved, so the next Scan & Plan picks up from there."
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Keep Running")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.cancelAllRuns()     // SIGINT, like Ctrl-C: dewey saves its work and exits by itself
        model.laya.stopForQuit()  // a laya-serve this app started never outlives it
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
