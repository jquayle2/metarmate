import Foundation
import UserNotifications

// MARK: - NotificationManager
// Owns local-notification permission and posting for weather alerts.
//
// No entitlement is required: these are LOCAL notifications (scheduled in-app from the
// background task), not remote push — only the runtime authorization below is needed. A Push
// Notifications capability would be wrong here and would only complicate provisioning.
@MainActor
final class NotificationManager {
    static let shared = NotificationManager()
    private init() {}

    // Request authorization exactly once, and ONLY from the first-watch-creation flow — never
    // at launch. Prompting before the user has any watch is premature; this no-ops unless the
    // status is still undetermined, so it shows the system prompt at most once.
    func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    // Fire a local notification immediately (nil trigger = deliver now). If authorization was
    // never granted the system simply drops it — the request itself is harmless.
    func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
