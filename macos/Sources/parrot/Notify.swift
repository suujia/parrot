import Foundation
import UserNotifications

/// Best-effort user-visible notification. From Parrot.app this goes through
/// UNUserNotificationCenter (authorization is requested lazily, on the first
/// notification). A bare `swift run parrot` binary has no bundle, which
/// UserNotifications requires, so it falls back to osascript.
func notifyUser(title: String, body: String) {
    if AppBundle.isBundled {
        UserNotifier.shared.post(title: title, body: body)
    } else {
        notifyViaOsascript(title: title, body: body)
    }
}

private func notifyViaOsascript(title: String, body: String) {
    func quoted(_ s: String) -> String {
        "\""
            + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    let script = "display notification \(quoted(body)) with title \(quoted(title))"
    let task = Process()
    task.launchPath = "/usr/bin/osascript"
    task.arguments = ["-e", script]
    try? task.run()
}

/// UNUserNotificationCenter wrapper. Also the center's delegate so banners
/// still show when Parrot happens to be the active app.
final class UserNotifier: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = UserNotifier()

    /// Call once at startup from a bundle so the delegate is in place before
    /// the first notification. Safe to call when not bundled (no-op).
    func install() {
        guard AppBundle.isBundled else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func post(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if granted {
                        self.deliver(title: title, body: body)
                    } else {
                        FileHandle.standardError.write(
                            Data("notifications not authorized\(error.map { ": \($0)" } ?? "") — \(title): \(body)\n".utf8))
                    }
                }
            case .authorized, .provisional:
                self.deliver(title: title, body: body)
            default:
                FileHandle.standardError.write(Data("notifications denied — \(title): \(body)\n".utf8))
            }
        }
    }

    private func deliver(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                FileHandle.standardError.write(Data("notification failed: \(error)\n".utf8))
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
