import Foundation
import UserNotifications

/// Local notifications for agents that need attention. Opt-in: the user turns it
/// on (which requests authorization) from the workspaces toolbar, and we only
/// fire on the transition *into* `.blocked`. iOS suppresses the banner while the
/// app is foregrounded — exactly the "don't nag me while I'm watching" behavior,
/// so there's no app-state check here.
// ponytail: relies on iOS's default foreground suppression instead of a
// UNUserNotificationCenterDelegate; add one only if we later want in-app banners.
enum AgentNotifier {
    static let enabledKey = "notifyOnBlocked"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Request authorization; returns whether it was granted. Call from the toggle
    /// so the system prompt is tied to an explicit user action, not a stray event.
    @discardableResult
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Fire a "needs input" notification for a pane that just became blocked.
    static func notifyBlocked(agent: String, workspace: String) {
        guard isEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(agent) needs input"
        content.body = workspace
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
