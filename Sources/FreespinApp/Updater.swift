import AppKit
import Sparkle
import SwiftUI
import UserNotifications

/// Sparkle auto-update against the GitHub release appcast. Only bundles built by build-app.sh carry
/// SUFeedURL and SUPublicEDKey, so `swift run` and unkeyed builds simply have no updater.
@MainActor
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    static let shared = Updater()
    private var controller: SPUStandardUpdaterController?
    private nonisolated static let notificationID = "update"

    var updater: SPUUpdater? { controller?.updater }

    func start() {
        guard controller == nil, Self.configured else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    private static var configured: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        return !((info["SUFeedURL"] as? String) ?? "").isEmpty && !((info["SUPublicEDKey"] as? String) ?? "").isEmpty
    }

    // Without a Dock icon a scheduled update alert opens behind other apps; a notification points at it.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        guard handleShowingUpdate, !state.userInitiated else { return }
        let content = UNMutableNotificationContent()
        content.title = "Freespin \(update.displayVersionString) is available"
        content.body = "Open Freespin to install it."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil))
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
    }
}

/// Gear menu items; hidden when the build has no updater.
struct UpdateMenuItems: View {
    @StateObject private var model = UpdateMenuModel()

    var body: some View {
        if let updater = Updater.shared.updater {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!model.canCheck)
            Toggle("Check for Updates Automatically", isOn: Binding(get: { model.automatic }, set: { on in
                updater.automaticallyChecksForUpdates = on
                model.automatic = on
            }))
        }
    }
}

@MainActor
private final class UpdateMenuModel: ObservableObject {
    @Published var canCheck = false
    @Published var automatic = false

    init() {
        guard let updater = Updater.shared.updater else { return }
        automatic = updater.automaticallyChecksForUpdates
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    }
}
