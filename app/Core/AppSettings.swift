import AppKit
import ServiceManagement

// The app-level settings the cookie-era `UsageManager` (and its `Settings` extension) used
// to own before task 11 deleted them: the macOS login item, the ⌘U shortcut preference,
// and the Accessibility status the shortcut needs. Split out into its own small
// `@MainActor` type now that the cookie manager is gone — there is no longer a polling
// object to hang these off, and they are
// genuinely app-level, not per-account (those live on `UsageStore`) and not notification
// (those live on `AccountNotifier`).
//
// It is deliberately NOT the notifications toggle: that state is `notifications_enabled`,
// owned by `AccountNotifier` (task 9 already honours it — advancing threshold state while
// gating delivery), and giving it a second home here would be the two-sources-of-truth
// the whole rework exists to remove.
//
// Login item and shortcut both reflect the REAL system state, not just a stored bool:
// `openAtLogin` reads `SMAppService.mainApp.status`, and `isAccessibilityEnabled` reads
// `AXIsProcessTrusted()` live. The stored `shortcut_enabled` key is the exception — it is
// a genuine user preference (whether to register the hotkey at all), with no system mirror
// to read back.
@MainActor
final class AppSettings: ObservableObject {
    static let shortcutEnabledKey = "shortcut_enabled"
    static let openAtLoginKey = "open_at_login"

    // §11: the one-time cookie-era key purge. Impure half of `DefaultsMigration` — reads
    // the present keys, applies the pure decision, and sets the marker. MUST run at launch
    // BEFORE `UsageStore` starts, so a key scheduled for deletion cannot be read back by
    // the store first. Idempotent: gated on the stored marker (second launch is a no-op)
    // and it only removes keys that are both dead and present (a fresh install writes just
    // the marker).
    static func runDefaultsMigrationIfNeeded(defaults: UserDefaults = .standard) {
        let present = Set(defaults.dictionaryRepresentation().keys)
        let alreadyMigrated = defaults.bool(forKey: DefaultsMigration.markerKey)
        let toPurge = DefaultsMigration.keysToPurge(present: present,
                                                    alreadyMigrated: alreadyMigrated)
        for key in toPurge {
            defaults.removeObject(forKey: key)
        }
        if !alreadyMigrated {
            defaults.set(true, forKey: DefaultsMigration.markerKey)
            NSLog("🧹 2.0.0 migration: purged %d dead cookie-era key(s)", toPurge.count)
        }
    }

    private let defaults: UserDefaults

    // Reflects the real login-item registration, refreshed after every change.
    @Published private(set) var openAtLogin: Bool
    // The user's preference: register the ⌘U hotkey or not. Default ON when unset,
    // matching the behaviour the cookie-era settings shipped with.
    @Published private(set) var shortcutEnabled: Bool
    // Live Accessibility trust — needed for the global hotkey to work in all apps.
    @Published private(set) var isAccessibilityEnabled: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.openAtLogin = AppSettings.systemLoginItemEnabled(fallback:
            defaults.bool(forKey: AppSettings.openAtLoginKey))
        if defaults.object(forKey: AppSettings.shortcutEnabledKey) == nil {
            self.shortcutEnabled = true
        } else {
            self.shortcutEnabled = defaults.bool(forKey: AppSettings.shortcutEnabledKey)
        }
        self.isAccessibilityEnabled = AXIsProcessTrusted()
    }

    // Re-read the live Accessibility state — the user may grant it in System Settings while
    // the popover is open, and the "grant permission" hint must clear when they do.
    func refreshAccessibility() {
        isAccessibilityEnabled = AXIsProcessTrusted()
    }

    // Re-read the REAL login-item registration — the user may toggle it in System Settings
    // (or a prior register have failed) while the app runs, and the settings toggle must
    // reflect the system, not a cached bool.
    func refreshLoginStatus() {
        openAtLogin = AppSettings.systemLoginItemEnabled(fallback: openAtLogin)
    }

    // Register/unregister the login item, then reflect the REAL resulting status rather
    // than the requested one — a registration can fail (or be blocked by the user in
    // System Settings), and a toggle stuck "on" over a login item that is actually off is
    // the stored-bool lie §7.3 calls out.
    func setOpenAtLogin(_ enabled: Bool) {
        applyLoginItem(enabled)
        openAtLogin = AppSettings.systemLoginItemEnabled(fallback: enabled)
        defaults.set(openAtLogin, forKey: AppSettings.openAtLoginKey)
    }

    // Records the preference only; the caller (AppDelegate) actually registers or
    // unregisters the Carbon hotkey, since it owns the hotkey ref and the event handler.
    func setShortcutEnabled(_ enabled: Bool) {
        shortcutEnabled = enabled
        defaults.set(enabled, forKey: AppSettings.shortcutEnabledKey)
    }

    private static func systemLoginItemEnabled(fallback: Bool) -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return fallback
    }

    private func applyLoginItem(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            NSLog("🔑 Login item %@", enabled ? "registered" : "unregistered")
        } catch {
            NSLog("❌ Login item error: %@", error.localizedDescription)
        }
    }
}
