import Foundation
import UserNotifications

/// A notification the day before the iPad app's install expires (7 days after installing with a free
/// Apple account), once per expiry date, with a Renew button that runs the install script.
enum RenewalReminder {
    static let lead: TimeInterval = 24 * 3600
    static let category = "ipad-renewal"
    static let renewAction = "renew"

    enum Plan: Equatable {
        case none           // already reminded about this expiry date
        case at(Date)       // a day before it expires
        case now(expired: Bool)
    }

    static func plan(expires: Date, now: Date, reminded: Date?) -> Plan {
        if reminded == expires { return .none }
        let due = expires.addingTimeInterval(-lead)
        return now < due ? .at(due) : .now(expired: now >= expires)
    }
}

/// Schedules the reminder and handles its Renew button. Only in the .app: UNUserNotificationCenter
/// needs an app bundle (it crashes in `swift run` or a test runner).
///
/// macOS can refuse notification permission outright, without asking (seen 2026-11-14 with this
/// self-signed app: no prompt, an error within 4 ms). Then `onAlert` shows the same reminder as the
/// app's own alert, at the same moment, as long as the app is running.
final class RenewalNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let canRenew: Bool
    private let onRenew: () -> Void
    private let onAlert: (_ title: String, _ body: String) -> Void
    private var pendingAlert: DispatchWorkItem?

    init(canRenew: Bool, onRenew: @escaping () -> Void, onAlert: @escaping (String, String) -> Void) {
        self.canRenew = canRenew
        self.onRenew = onRenew
        self.onAlert = onAlert
        super.init()
        center.delegate = self
        let renew = UNNotificationAction(identifier: RenewalReminder.renewAction, title: "Renew", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: RenewalReminder.category,
                                                                 actions: canRenew ? [renew] : [], intentIdentifiers: [])])
    }

    /// Call with every expiry date the iPad app reports, and at launch. A new date replaces the pending one.
    func update(expires: Date, defaults: UserDefaults = .standard) {
        let reminded = defaults.object(forKey: Settings.Key.remindedExpiry) as? Date
        let plan = RenewalReminder.plan(expires: expires, now: Date(), reminded: reminded)
        guard plan != .none else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async {
                defaults.set(granted ? nil : error.map { "\($0)" } ?? "declined", forKey: Settings.Key.notificationError)
                if granted {
                    self.notify(plan, expires: expires)
                    defaults.set(expires, forKey: Settings.Key.remindedExpiry)   // the system keeps it from here
                } else {
                    self.alertWhenDue(plan, expires: expires, defaults: defaults)
                }
            }
        }
    }

    private func text(expires: Date, relativeTo now: Date) -> (title: String, body: String) {
        let when = RelativeDateTimeFormatter().localizedString(for: expires, relativeTo: now)
        return (now >= expires ? "The iPad app expired \(when)" : "The iPad app expires \(when)",
                canRenew ? "Renew it with the iPad unlocked and plugged in or nearby, so it keeps opening."
                         : "Run scripts/install-ipad.sh again to renew it, so it keeps opening.")
    }

    private func notify(_ plan: RenewalReminder.Plan, expires: Date) {
        var due = Date()
        var trigger: UNNotificationTrigger?
        if case .at(let date) = plan {
            due = date
            trigger = UNCalendarNotificationTrigger(
                dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date),
                repeats: false)
        }
        let content = UNMutableNotificationContent()
        content.categoryIdentifier = RenewalReminder.category
        content.sound = .default
        (content.title, content.body) = text(expires: expires, relativeTo: due)
        center.add(UNNotificationRequest(identifier: RenewalReminder.category, content: content, trigger: trigger))
    }

    private func alertWhenDue(_ plan: RenewalReminder.Plan, expires: Date, defaults: UserDefaults) {
        var delay = 0.0
        if case .at(let date) = plan { delay = max(0, date.timeIntervalSinceNow) }
        pendingAlert?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            defaults.set(expires, forKey: Settings.Key.remindedExpiry)   // only once shown: the timer dies with the app
            let text = self.text(expires: expires, relativeTo: Date())
            self.onAlert(text.title, text.body)
        }
        pendingAlert = work
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + delay, execute: work)   // wall clock: counts sleep too
    }

    // A menu bar app counts as active while its menu is open, so show banners then too.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == RenewalReminder.renewAction { DispatchQueue.main.async(execute: onRenew) }
        completionHandler()
    }
}
