import Foundation
import UserNotifications

// MARK: - NotificationManager
// Owns local-notification permission, posting, and foreground presentation for weather alerts.
//
// No entitlement is required: these are LOCAL notifications (scheduled in-app from the
// background task), not remote push — only the runtime authorization below is needed. A Push
// Notifications capability would be wrong here and would only complicate provisioning.
//
// It is the UNUserNotificationCenter delegate (set at launch) so that foreground-delivered
// notifications actually present — see willPresent below.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()
    private override init() { super.init() }

    // Request authorization exactly once, and ONLY from the first-watch-creation flow — never
    // at launch. Prompting before the user has any watch is premature; this no-ops unless the
    // status is still undetermined, so it shows the system prompt at most once.
    func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    // Fire a local notification immediately (nil trigger = deliver now). Uses the throwing
    // async add so iOS's accept/reject is observed, not swallowed: logs any failure and returns
    // whether the request was actually accepted, so callers count CONFIRMED posts rather than
    // mere intentions.
    @discardableResult
    func post(title: String, body: String) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            print("[NotificationManager] post failed for \"\(title)\": \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - UNUserNotificationCenterDelegate
    // Present alerts even while the app is foregrounded. Without this, an immediate (nil-trigger)
    // notification delivered while the app is in the foreground is suppressed by iOS entirely —
    // no banner AND not added to Notification Center — which is exactly why a granted-permission
    // post showed nothing. Returning .list ensures it also lands in Notification Center.
    //
    // Scope: foreground PRESENTATION only. Quiet-hours / interruption-level handling is a
    // separate Step 5 concern (it needs the settings UI) and is deliberately not here.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
