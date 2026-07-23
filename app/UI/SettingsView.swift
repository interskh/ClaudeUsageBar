import SwiftUI
import AppKit

// §7.3's settings, on the new engine. Every control here writes to the ONE owner of the
// state it changes and reads it back from there — no second source of truth:
//   • per-account enable  → `UsageStore.setEnabled(_:for:)` (task 7 skips polling a
//     disabled account; this surfaces the switch)
//   • notifications        → `AccountNotifier` (the `notifications_enabled` key task 9
//     already honours) + its preserved `sendTestNotification`
//   • Open-at-Login        → `AppSettings` (real `SMAppService` status, not a stored bool)
//   • ⌘U shortcut          → `AppSettings` preference + the AppDelegate's Carbon hotkey,
//     with the Accessibility prompt
//   • registered locations → `UsageStore.registeredLocations` (§4.1's escape hatch),
//     validated at add-time so a bad path is reported, not silently dropped.
struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var appSettings: AppSettings
    let notifier: AccountNotifier

    // AccountNotifier is not an ObservableObject (it is the impure delivery shell), so its
    // master toggle is mirrored locally and written through on change.
    @State private var notificationsEnabled: Bool

    // Registered locations are read from the store into local state so the list re-renders
    // on add/remove; `registeredLocations` is a plain property, not @Published.
    @State private var locations: [String]
    @State private var newLocation: String = ""
    @State private var locationError: String?

    init(store: UsageStore, appSettings: AppSettings, notifier: AccountNotifier) {
        self.store = store
        self.appSettings = appSettings
        self.notifier = notifier
        _notificationsEnabled = State(initialValue: notifier.isEnabled)
        _locations = State(initialValue: store.registeredLocations)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            accountsSection
            Divider()
            notificationsSection
            Divider()
            loginAndShortcutSection
            Divider()
            locationsSection
        }
        .padding(8)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(6)
        .onAppear {
            // Re-read the authoritative values, which can change outside this view while
            // the app runs: Accessibility and the login item can be toggled in System
            // Settings, and the location list can change from a background survey. The
            // notifications master toggle is only ever written here, but re-reading keeps
            // one source of truth. `store.accounts` is @Published and observed directly, so
            // the per-account checkboxes need no manual refresh.
            appSettings.refreshAccessibility()
            appSettings.refreshLoginStatus()
            locations = store.registeredLocations
            notificationsEnabled = notifier.isEnabled
        }
    }

    // MARK: - Per-account enable (§7.3)

    // Discovered accounts, grouped under their provider header, each with a checkbox. All
    // on by default (task 7). A disabled account is never polled; this is only the control.
    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ACCOUNTS")
                .font(.caption.weight(.bold))
                .foregroundColor(.secondary)
                .tracking(0.5)

            if store.accounts.isEmpty {
                Text("No accounts discovered.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                ForEach(providerGroups, id: \.provider) { group in
                    Text(Self.providerHeader(group.provider))
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary)
                    ForEach(group.accounts, id: \.ref.id) { account in
                        Toggle(isOn: Binding(
                            get: { store.isEnabled(account.ref.id) },
                            set: { store.setEnabled($0, for: account.ref.id) }
                        )) {
                            Text(account.ref.label).font(.caption)
                        }
                        .toggleStyle(.checkbox)
                        .padding(.leading, 8)
                    }
                }
            }
        }
    }

    // Exhaustive switch (not a two-way ternary) so a third provider forces a compile error
    // here rather than being silently mislabelled — matching PopoverView.providerName.
    private static func providerHeader(_ provider: ProviderKind) -> String {
        switch provider {
        case .anthropic: return "CLAUDE"
        case .codex: return "CODEX"
        }
    }

    private var providerGroups: [(provider: ProviderKind, accounts: [AccountPresentation])] {
        var groups: [(provider: ProviderKind, accounts: [AccountPresentation])] = []
        for account in store.accounts {
            if var last = groups.last, last.provider == account.ref.provider {
                last.accounts.append(account)
                groups[groups.count - 1] = last
            } else {
                groups.append((provider: account.ref.provider, accounts: [account]))
            }
        }
        return groups
    }

    // MARK: - Notifications (§7.3, repointed to AccountNotifier)

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { notificationsEnabled },
                set: { newValue in
                    notificationsEnabled = newValue
                    notifier.isEnabled = newValue
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable Notifications").font(.caption)
                    Text("Get alerts at 25%, 50%, 75%, and 90% usage")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)

            Button("Test Notification") { notifier.sendTestNotification() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    // MARK: - Login item + ⌘U shortcut (§7.3)

    private var loginAndShortcutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(
                get: { appSettings.openAtLogin },
                set: { appSettings.setOpenAtLogin($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open at Login").font(.caption)
                    Text("Launch app automatically when you log in")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(
                    get: { appSettings.shortcutEnabled },
                    set: { newValue in
                        appSettings.setShortcutEnabled(newValue)
                        // AppDelegate owns the Carbon hotkey ref and event handler.
                        (NSApplication.shared.delegate as? AppDelegate)?
                            .setShortcutEnabled(newValue)
                        appSettings.refreshAccessibility()
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keyboard Shortcut (⌘U)").font(.caption)
                        Text("Toggle popup from anywhere.\nDisable if it conflicts with other apps.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)

                if appSettings.shortcutEnabled && !appSettings.isAccessibilityEnabled {
                    Button("Grant Accessibility Permission") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Text("Accessibility permission may be needed\nfor the shortcut to work in all apps")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Registered config locations (§4.1's escape hatch)

    private var locationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CONFIG LOCATIONS")
                .font(.caption.weight(.bold))
                .foregroundColor(.secondary)
                .tracking(0.5)
            Text("Track a Claude config in a non-standard folder.")
                .font(.caption2)
                .foregroundColor(.secondary)

            ForEach(locations, id: \.self) { location in
                HStack(spacing: 6) {
                    Text(location)
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button {
                        store.removeLocation(location)
                        locations = store.registeredLocations
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this location")
                }
            }

            HStack(spacing: 6) {
                TextField("/path/to/config", text: $newLocation)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption2)
                    .onSubmit(addLocation)
                Button("Add", action: addLocation)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(newLocation.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let error = locationError {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func addLocation() {
        let candidate = newLocation.trimmingCharacters(in: .whitespaces)
        guard !candidate.isEmpty else { return }
        switch store.validateLocation(candidate) {
        case .accepted(let normalizedPath, let label):
            // The store re-validates internally (defence at the owner); pass the raw
            // candidate so a single validation contract governs what gets persisted.
            store.addLocation(candidate)
            locations = store.registeredLocations
            newLocation = ""
            locationError = nil
            NSLog("📁 Registered config location %@ (%@)", normalizedPath, label)
        case .rejected(let reason):
            // Reported, NOT registered — §4.1 forbids accepting a location that fails the
            // identity gate and then silently ignoring it.
            locationError = reason
        }
    }
}
