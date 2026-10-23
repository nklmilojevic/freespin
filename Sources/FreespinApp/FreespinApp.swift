import AppKit
import ServiceManagement
import SwiftUI

/// Freespin runs as a background agent: no Dock icon (LSUIElement + accessory policy), the engine keeps
/// driving the mouse with the window closed, and opening the app again brings the window back.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    /// Set by the window on first appearance; reopens it after it has been closed.
    var openMainWindow: (() -> Void)?
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.start()
        if launchedAtLogin {
            // Start straight into the background; the window opens on the next launch from Finder/Spotlight.
            DispatchQueue.main.async { NSApp.windows.forEach { $0.orderOut(nil) } }
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Scrolling keeps working with the window closed; Quit restores native scrolling.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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

    var body: some Scene {
        Window("Freespin", id: "main") {
            MainWindow(delegate: delegate)
                .environment(delegate.model)
                .frame(minWidth: 760, minHeight: 520)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// Hands the scene's `openWindow` action to the app delegate so a closed window can be reopened.
private struct MainWindow: View {
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView()
            .onAppear { delegate.openMainWindow = { openWindow(id: "main") } }
    }
}

/// "Open at login" through SMAppService (macOS 13+); a login launch starts hidden.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
