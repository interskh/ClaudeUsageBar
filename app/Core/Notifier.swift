import AppKit

extension UsageManager {
    func checkNotificationThresholds(percentage: Int) {
        // NEUTERED (task 9): threshold notifications now come from the real `AccountNotifier`
        // (per-account, per-window, from OAuth `limits[]`), which is the ONLY notification
        // source in the new app. This legacy path fired from cookie-cache data — including a
        // stale one-shot at launch via `loadCachedUsage → updateStatusBar` — which is the
        // exact false "Claude Usage Alert" this rework exists to stop trusting, and would
        // also double the real path. A no-op suppresses it. Task 11 deletes this file.
        _ = percentage
    }

    func sendNotification(percentage: Int, threshold: Int) {
        let notification = NSUserNotification()
        notification.title = "Claude Usage Alert"
        notification.informativeText = "You've reached \(percentage)% of your 5-hour session limit"
        notification.soundName = NSUserNotificationDefaultSoundName

        NSUserNotificationCenter.default.deliver(notification)
        NSLog("📬 Sent notification for \(threshold)% threshold")
    }

    func sendTestNotification() {
        NSLog("🔔 Test notification button clicked")

        let notification = NSUserNotification()
        notification.title = "Claude Usage Alert"
        notification.informativeText = "Test notification - You've reached 75% of your 5-hour session limit"
        notification.soundName = NSUserNotificationDefaultSoundName

        NSUserNotificationCenter.default.deliver(notification)
        NSLog("📬 Test notification sent successfully")
    }
}
