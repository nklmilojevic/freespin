import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Scrolling keeps working with the window closed; Quit restores native scrolling.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { for window in sender.windows { window.makeKeyAndOrderFront(nil) } }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task { @MainActor in
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct FreespinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Freespin", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 520)
                .task {
                    delegate.model = model
                    model.start()
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
