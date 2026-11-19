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
            CommandGroup(replacing: .help) {
                Button("Dewey Help") { NSWorkspace.shared.open(Self.help) }
            }
        }
        Settings {
            PreferencesView()
                .environment(delegate.model)
        }
    }

    /// The README's Mac app section.
    static let help = URL(string: "https://github.com/thatcherstudio/dewey#mac-app")!
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)  // a Dock icon and menus even when run with `swift run`
        NSApp.activate()
        Task { await model.launch() }
    }

    /// A scan or move in progress is safe to stop (it keeps what's done, moves stay undoable), but say so
    /// before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let unsaved = model.foldersWithUnsavedChanges, unsavedSettings = model.foldersWithUnsavedSettings
        if !unsaved.isEmpty || !unsavedSettings.isEmpty {
            let alert = NSAlert()
            alert.messageText = unsavedSettings.isEmpty ? "Quit without saving your changes to the plan?"
                : unsaved.isEmpty ? "Quit without saving your settings?" : "Quit without saving your changes?"
            alert.informativeText = [
                unsaved.isEmpty ? nil : "Review has unsaved changes for \(unsaved.map(\.name).joined(separator: ", ")).",
                unsavedSettings.isEmpty ? nil
                    : "Settings has unsaved changes for \(unsavedSettings.map(\.name).joined(separator: ", ")).",
                "Quitting drops them; the files on disk stay as they were.",
            ].compactMap { $0 }.joined(separator: " ")
            alert.addButton(withTitle: "Keep Editing")
            alert.addButton(withTitle: "Quit Anyway")
            guard alert.runModal() == .alertSecondButtonReturn else {
                if let f = unsaved.first {
                    model.selection = .folder(f.path)
                    f.openReview()
                } else if let f = unsavedSettings.first {
                    model.selection = .folder(f.path)
                    f.tab = .settings
                }
                return .terminateCancel
            }
        }
        let busy = model.busyFolders, installing = model.installer.isRunning
        guard !busy.isEmpty || installing else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = busy.isEmpty ? "Stop installing Laya and quit?"
            : busy.count == 1 ? "Stop \(busy[0].activity) in \(busy[0].name) and quit?"
            : "Stop dewey in \(busy.count) folders and quit?"
        alert.informativeText = [
            busy.isEmpty ? nil
                : busy.contains { $0.moveRun?.isActive == true || $0.undoRun?.isActive == true }
                ? "Dewey stops after the file in hand. Files already moved stay where they are now, and History can "
                    + "put them back."
                : "Everything finished so far is saved, so the next Scan & Plan picks up from there.",
            installing ? "Installing Laya stops too. What it downloaded is kept, so installing again picks up from there."
                : nil,
        ].compactMap { $0 }.joined(separator: " ")
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Keep Running")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.cancelAllRuns()     // SIGINT, like Ctrl-C: dewey saves its work and exits by itself
        model.laya.stopForQuit()  // a laya-serve this app started never outlives it
        model.installer.stopForQuit()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
