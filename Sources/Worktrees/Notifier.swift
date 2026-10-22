import AppKit
import ServiceManagement
import UserNotifications

/// macOS notifications for failed checks and merged PRs. The notification center only exists
/// for a real app bundle: a bare `swift build` binary would crash asking for it, so every call
/// checks first and does nothing there or in demo runs.
@MainActor
enum Notifier {
    /// Never under tests or in the test copy of the app, so neither can post a real notification.
    static var available: Bool {
        Bundle.main.bundleIdentifier != nil && !DemoData.isOn && !TestMode.on
    }

    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        /// A click opens the PR on GitHub.
        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
            guard let raw = response.notification.request.content.userInfo["url"] as? String,
                  let url = URL(string: raw), url.scheme == "https", url.host()?.lowercased() == "github.com"
            else { return }
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
        }

        /// Shown even while the app is in front, since the row may be scrolled out of view.
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
            [.banner, .sound]
        }
    }

    private static let delegate = Delegate()

    static func setUp() {
        guard available else { return }
        UNUserNotificationCenter.current().delegate = delegate
    }

    /// Asks once, when a notification setting is first turned on. False when macOS says no.
    static func requestPermission() async -> Bool {
        guard available else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Whether macOS lets the app show notifications at all, for Settings to warn when not.
    static func allowed() async -> Bool {
        guard available else { return false }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    /// Tests catch notifications here instead of showing them.
    static var sink: ((_ title: String, _ body: String, _ url: String) -> Void)?

    static func post(title: String, body: String, url: String) {
        if let sink { sink(title, body, url); return }
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["url": url]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// Open at login, through the system's Login Items. macOS keeps the state, so Settings reads
/// it back rather than storing its own copy.
@MainActor
enum LoginItem {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    /// Login Items point at this copy of the app, so one run from a build folder breaks when
    /// that folder is rebuilt or deleted.
    static var outsideApplications: Bool { !Bundle.main.bundlePath.hasPrefix("/Applications/") }

    /// nil on success, otherwise what went wrong.
    static func set(_ on: Bool) -> String? {
        guard !DemoData.isOn, !TestMode.on, Bundle.main.bundleIdentifier != nil else {
            return "Only the installed app can open at login."
        }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
