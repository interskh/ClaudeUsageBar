import AppKit

// §8, the DELIVERY half. IMPURE: it turns the pure `NotificationEngine`'s decisions into
// `NSUserNotification`s and owns the on/off master toggle and the `UserDefaults` blob. It
// decides NOTHING about thresholds, hysteresis, or per-window state — all of that lives
// in `Model/NotificationEngine`, which the test target compiles. This is the same
// pure/impure split task 7 used (`Model/UsageEngine` + `Core/UsageStore`): policy in the
// tested target, transport in the app-only shell.
//
// @MainActor: it owns `UserDefaults` and is driven from `UsageStore` (also @MainActor),
// and the engine it holds is @MainActor, so the whole thing sits in §6's single-writer
// domain by the type system rather than by convention.
//
// DEPRECATION CARRIED FORWARD: `NSUserNotification` is superseded by
// `UserNotifications`/`UNUserNotificationCenter`. Migrating needs an authorization flow
// and a bundle-identity story out of scope for this correctness fix, and the app ships on
// `NSUserNotification` today — the same API the deleted cookie-era `Core/Notifier.swift`
// used. Kept to match that convention; the migration is a separate piece of work.
@MainActor
final class AccountNotifier {
    // The same defaults key the shipped app used for the master toggle, so a user who
    // had notifications off keeps them off across this change.
    static let enabledKey = "notifications_enabled"
    // The per-(account, window) threshold state, one versioned blob. Distinct from the
    // shipped `last_notified_threshold` Int, which is left untouched and simply unused.
    static let stateKey = "notify.v1.state"

    private let defaults: UserDefaults
    private let engine: NotificationEngine

    // Master switch. Absent defaults to ON, matching the shipped `Settings.load`.
    var isEnabled: Bool {
        get {
            if defaults.object(forKey: AccountNotifier.enabledKey) == nil { return true }
            return defaults.bool(forKey: AccountNotifier.enabledKey)
        }
        set { defaults.set(newValue, forKey: AccountNotifier.enabledKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // The restore/reclaim decision is a pure function so it can be tested; only the
        // side effects (build the engine, delete a corrupt blob) live here.
        switch NotificationRestore.decide(defaults.data(forKey: AccountNotifier.stateKey)) {
        case .empty:
            self.engine = NotificationEngine()
        case .restore(let state):
            self.engine = NotificationEngine(restoring: state)
        case .reclaim:
            // Present but undecodable (corrupt or old-version): remove it rather than
            // leave it to be re-read and re-fail every launch. Its state was already
            // unreadable, so nothing recoverable is lost.
            self.engine = NotificationEngine()
            defaults.removeObject(forKey: AccountNotifier.stateKey)
        }
    }

    // The wiring point for tasks 9–11: call once per publish with the store's full
    // presentation set. `NotificationEngine.inputs` splits it into the readable readings
    // and the authoritative roster (see `NotificationEngine.evaluate`). State is advanced
    // and persisted regardless of the master toggle — so turning notifications back on
    // starts from current levels rather than dumping a backlog — while DELIVERY is gated
    // by it.
    func evaluate(_ presentations: [AccountPresentation]) {
        let inputs = NotificationEngine.inputs(from: presentations)
        let alerts = engine.evaluate(inputs.readings, discovered: inputs.discovered)
        if let state = engine.drainPersistence() {
            if let payload = PersistedCodec.encode(state) {
                defaults.set(payload, forKey: AccountNotifier.stateKey)
            }
        }
        guard isEnabled else { return }
        for alert in alerts { deliver(alert) }
    }

    private func deliver(_ alert: NotificationAlert) {
        let notification = NSUserNotification()
        // Titled from the alert's own provider — never a hardcoded "Claude" that would
        // mislabel a Codex reading.
        notification.title = alert.title
        notification.informativeText = alert.summary
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
        NSLog("📬 Notification: %@ — %@", alert.title, alert.summary)
    }

    // Preserved so task 11's Settings "Test notification" button has something to call —
    // the shipped `UsageManager.sendTestNotification` goes away with `LegacyUsageManager`.
    func sendTestNotification() {
        let notification = NSUserNotification()
        notification.title = "Claude Usage Alert"
        notification.informativeText = "Test notification — this is how a usage alert looks."
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
        NSLog("📬 Test notification sent")
    }
}
