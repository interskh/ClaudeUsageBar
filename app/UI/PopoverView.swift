import SwiftUI
import AppKit

// §7.2's popover: one collapsed row per discovered account, grouped under provider
// headers, each row expandable to its per-window bars, reset lines and the Extra dollar
// line. The data source is `UsageStore` ALONE for the cards — every figure is an engine
// projection under one consistent view (§7.1/§7.2), never re-derived here. The legacy
// cookie manager survives only as the settings backing (notifications toggle, Open-at-
// Login, ⌘U); task 11 repoints those and deletes it. Nothing in this file computes a
// utilization: the row figure is `Snapshot.bindingUtilization`, the single-sourced
// function the menu bar also uses, so the popover and the menu bar cannot disagree.
struct UsageView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var usageManager: UsageManager
    @State private var showingSettings: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if store.accounts.isEmpty {
                    Text("No accounts discovered.\nSign in via Claude Code or Codex.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 8)
                } else {
                    ForEach(providerGroups, id: \.provider) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(providerName(group.provider))
                                .font(.caption.weight(.bold))
                                .foregroundColor(.secondary)
                                .tracking(0.5)
                            ForEach(group.accounts, id: \.ref.id) { account in
                                AccountCard(account: account, store: store)
                            }
                        }
                    }
                }

                Divider()

                HStack {
                    Text(store.lastSuccessAt.map { "Updated \(Self.timeString($0))" } ?? "Not yet updated")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Refresh") { store.refresh() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }

                settingsSection
            }
            .padding()
        }
        .frame(width: 320)
    }

    // Accounts arrive already sorted by provider then label (engine `sortedKeys`), so a
    // provider header is emitted only when a provider actually has accounts — a provider
    // with none is simply never encountered, satisfying §7.2's "omit empty sections".
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

    private func providerName(_ provider: ProviderKind) -> String {
        switch provider {
        case .anthropic: return "CLAUDE"
        case .codex: return "CODEX"
        }
    }

    // MARK: - Settings (interim: still backed by the legacy manager's UserDefaults
    // settings — task 11 replaces this whole sub-view with the §7.3 SettingsView).

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(showingSettings ? "Hide Settings" : "Settings") {
                showingSettings.toggle()
            }
            .buttonStyle(.borderless)
            .font(.caption)

            if showingSettings {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: Binding(
                        get: { usageManager.openAtLogin },
                        set: { newValue in
                            usageManager.openAtLogin = newValue
                            usageManager.applyLoginItem(newValue)
                            usageManager.saveSettings()
                        }
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
                            get: { usageManager.notificationsEnabled },
                            set: { newValue in
                                usageManager.notificationsEnabled = newValue
                                usageManager.saveSettings()
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Enable Notifications").font(.caption)
                                Text("Get alerts at 25%, 50%, 75%,\nand 90% usage")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.checkbox)

                        Button("Test Notification") {
                            usageManager.sendTestNotification()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: Binding(
                            get: { usageManager.shortcutEnabled },
                            set: { newValue in
                                usageManager.shortcutEnabled = newValue
                                usageManager.saveSettings()
                                if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                                    appDelegate.setShortcutEnabled(newValue)
                                }
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

                        if usageManager.shortcutEnabled && !usageManager.isAccessibilityEnabled {
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
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
            }
        }
    }

    static func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }
}

// One account's collapsed row, expandable to its windows and Extra line. It renders
// exactly the state the engine handed it: `pending` is a spinner (NEVER a zeroed bar,
// which reads as a genuine 0%), `signedOut`/`expired` are a non-expandable sign-in hint
// (NEVER an error), `stale` carries an "as of" time, and a rate-limited account shows its
// degraded cadence. `.unknown` renders as "—", never 0% and never another window's number.
private struct AccountCard: View {
    let account: AccountPresentation
    let store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if account.isExpanded, let snapshot = account.state.readableSnapshot {
                expandedBody(snapshot)
                    .padding(.leading, 16)
                    .padding(.top, 2)
            } else if let note = account.degradationNote {
                // §6/§7.2: a stretched cadence must be visible on the account's OWN card —
                // and a rate-limited account is .active/.stale, so its default COLLAPSED
                // row would otherwise show a plain bar and read as fresh. When expanded,
                // `expandedBody` already carries the note; this is the collapsed twin.
                Text(note)
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .padding(.leading, 16)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if isExpandable {
                Image(systemName: account.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 10)
            } else {
                // Keep the label column aligned with expandable rows.
                Color.clear.frame(width: 10, height: 1)
            }

            Text(account.ref.label)
                .font(.subheadline)
                .lineLimit(1)

            Spacer(minLength: 8)

            trailing
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard isExpandable else { return }
            store.setExpanded(!account.isExpanded, for: account.ref.id)
        }
    }

    // The right-hand summary for the collapsed row, one rendering per state category.
    @ViewBuilder private var trailing: some View {
        switch account.state {
        case .pending:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
                .frame(height: 12)
        case .signedOut, .expired:
            // The recovery CLI is the account's OWN provider's — a lapsed Codex account
            // must not be told to sign in via Claude Code.
            Text("Sign in via \(account.ref.provider.cliName)")
                .font(.caption)
                .foregroundColor(.secondary)
        case .failed(let note):
            Text(note)
                .font(.caption)
                .foregroundColor(.orange)
                .lineLimit(1)
        case .active(let snapshot), .stale(let snapshot, _):
            UsageBar(utilization: Snapshot.bindingUtilization(of: snapshot.windows) ?? .unknown)
                .frame(width: 120)
        }
    }

    // Only an account with a readable snapshot (active/stale) has windows to expand into.
    private var isExpandable: Bool { account.state.readableSnapshot != nil }

    @ViewBuilder private func expandedBody(_ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if case .stale(_, _) = account.state {
                Text("as of \(UsageView.timeString(snapshot.fetchedAt))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            if let note = account.degradationNote {
                Text(note)
                    .font(.caption2)
                    .foregroundColor(.orange)
            }

            ForEach(Array(snapshot.windows.enumerated()), id: \.offset) { _, window in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(window.label)
                            .font(.caption)
                        Spacer(minLength: 8)
                        UsageBar(utilization: window.utilization)
                            .frame(width: 110)
                    }
                    if let resets = window.resetsAt {
                        Text("resets \(Self.resetString(resets, span: window.id.span))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if let extra = snapshot.spend?.extraLine {
                HStack(spacing: 6) {
                    Text("Extra").font(.caption)
                    Spacer(minLength: 8)
                    Text(extra)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // Session-class windows reset within a day, so a wall-clock time is what the user
    // needs; longer windows reset days out, so weekday + date. The window's SPAN decides
    // the format, never a hardcoded per-window string.
    private static func resetString(_ date: Date, span: WindowSpan) -> String {
        let f = DateFormatter()
        switch span {
        case .session:
            f.timeStyle = .short
            f.dateStyle = .none
        case .weekly, .other:
            f.dateFormat = "EEE d MMM"
        }
        return f.string(from: date)
    }
}

// A percentage as a coloured bar plus its number, or "—" when unknown. `.unknown` is
// NOT 0%: it renders with no fill and a dash, so an account we cannot read right now is
// visibly distinct from one genuinely idle at 0%.
private struct UsageBar: View {
    let utilization: Utilization

    var body: some View {
        switch utilization {
        case .known(let percent):
            HStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.2))
                        Capsule()
                            .fill(color(percent))
                            .frame(width: max(0, min(1, Double(percent) / 100)) * geo.size.width)
                    }
                }
                .frame(height: 6)
                Text("\(percent)%")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
        case .unknown:
            HStack(spacing: 6) {
                Capsule()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: 6)
                Text("—")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
        }
    }

    private func color(_ percent: Int) -> Color {
        if percent < 70 { return .green }
        if percent < 90 { return .orange }
        return .red
    }
}

// The two states carrying a readable snapshot (active/stale). Every other state has no
// windows to show and its row is not expandable — the §7.2 rule that signedOut/expired/
// pending are distinct renderings, not empty cards.
private extension AccountState {
    var readableSnapshot: Snapshot? {
        switch self {
        case .active(let snapshot): return snapshot
        case .stale(let snapshot, _): return snapshot
        case .pending, .signedOut, .expired, .failed: return nil
        }
    }
}
