import AppKit
import SwiftUI

@main
struct DeweyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Dewey", id: "main") {
            ContentView()
                .environment(delegate.model)
                .frame(minWidth: 640, minHeight: 480)
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

    func applicationWillTerminate(_ notification: Notification) {
        model.laya.stopForQuit()  // a laya-serve this app started never outlives it
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
