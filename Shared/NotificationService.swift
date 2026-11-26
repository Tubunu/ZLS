import Foundation
import UserNotifications

public final class NotificationService {
    public static let shared = NotificationService()

    private init() {}

    public func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    public func postScrollshotReadyNotification(recordingID: String, frameCount: Int) {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("scrollshot.notification.title", comment: "")
        content.body = String(
            format: NSLocalizedString("scrollshot.notification.body", comment: ""),
            frameCount
        )
        content.sound = .default
        content.userInfo = ["recordingID": recordingID]

        let request = UNNotificationRequest(
            identifier: "\(AppGroupStore.scrollshotNotificationID).\(recordingID)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.25, repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
    }
}
