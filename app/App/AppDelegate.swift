import SwiftUI
import AppKit
import Carbon
import Combine

// Main entry point.
//
// `@MainActor` on the whole class (§6): `UsageStore` is `@MainActor`, and it is the
// single owner of the app's one polling loop. AppKit already drives every delegate
// callback and every `@objc` action here on the main thread, so annotating the class
// makes what was already true checkable — the store's main-actor methods are called from
// an isolated context rather than smuggled across a boundary. Three places hand control
// back through a non-Swift-concurrency path and each reaches this @MainActor delegate via
// `MainActor.assumeIsolated`, correct because all three are delivered on the main thread:
// (1) the Carbon hotkey C callback (`togglePopover`); (2) the `store.$menuBar` Combine
// sink (`renderMenuBar`); (3) the `store.$accounts` Combine sink (`notifier.evaluate`).
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    // The single polling owner (§6). Everything on screen is a projection it published.
    var store: UsageStore!
    // §8's delivery half. Driven off `store.$accounts` (the FULL roster, every publish) —
    // NOT `$menuBar`, which is the coalesced worst-of subset. `evaluate` advances threshold
    // state regardless of the master toggle and gates only DELIVERY on it, so the saved
    // `notifications_enabled` preference is honoured from now (a v1.3.2 user who turned
    // notifications off stays quiet). This is the only notification source in the new app.
    var notifier: AccountNotifier!
    // Kept only so the cookie-era popover/settings still compile until tasks 10–11 replace
    // them. It is deliberately INERT: instantiated but never told to fetch or start a
    // timer, so the app has exactly ONE polling loop — the store's.
    var usageManager: UsageManager!
    var menuBarObserver: AnyCancellable?
    var accountsObserver: AnyCancellable?
    var eventMonitor: Any?
    var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The UI is designed for dark; force dark appearance regardless of the
        // system light/dark setting (light mode had poor contrast).
        NSApp.appearance = NSAppearance(named: .darkAqua)

        // NSUserNotification (deprecated but works without permissions for unsigned apps)
        NSLog("✅ App launched, notifications ready")

        // Create status bar item with variable length for compact display
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            // Neutral idle glyph until the store publishes its first figures.
            renderMenuBar([])
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self

            // Force the button to be visible
            button.appearsDisabled = false
            button.isEnabled = true
        }

        // The new multi-provider engine — the SINGLE polling owner. The menu bar is driven
        // off its `@Published menuBar`, not a second timer.
        store = UsageStore()
        menuBarObserver = store.$menuBar
            .receive(on: RunLoop.main)
            .sink { [weak self] figures in
                MainActor.assumeIsolated { self?.renderMenuBar(figures) }
            }

        // §8: the real threshold notifier, wired to the FULL roster the store republishes
        // every cycle. Per-(account, window) crossings, honouring the saved master toggle.
        notifier = AccountNotifier()
        accountsObserver = store.$accounts
            .receive(on: RunLoop.main)
            .sink { [weak self] accounts in
                MainActor.assumeIsolated { self?.notifier.evaluate(accounts) }
            }

        store.start()

        // Cookie-era manager: instantiated ONLY so `UsageView`/`Settings` still compile
        // (tasks 10–11 remove them). It must NOT poll — do not call `fetchUsage()` or
        // `startRefreshTimer()`. Its `init` only reads UserDefaults (no timer, no network,
        // no Keychain), so leaving those two calls off makes it fully inert and guarantees
        // the app has exactly one polling loop hitting the rate-limited endpoints.
        usageManager = UsageManager(statusItem: statusItem, delegate: self)

        // Create popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 450)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: UsageView(usageManager: usageManager))

        // Set up Cmd+U keyboard shortcut
        setupKeyboardShortcut()
    }

    func setupKeyboardShortcut() {
        // Check Accessibility permissions
        checkAccessibilityPermissions()

        // Only register if user has the shortcut enabled
        if usageManager.shortcutEnabled {
            registerGlobalHotKey()
        }
    }

    func setShortcutEnabled(_ enabled: Bool) {
        if enabled {
            registerGlobalHotKey()
        } else {
            unregisterGlobalHotKey()
        }
    }

    func checkAccessibilityPermissions() {
        // Check if app has Accessibility permissions
        let trusted = AXIsProcessTrusted()

        if !trusted {
            NSLog("⚠️ Accessibility permissions not granted")
            // Show alert to guide user
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let alert = NSAlert()
                alert.messageText = "Accessibility Permission Required"
                alert.informativeText = "ClaudeUsageBar needs Accessibility permission to use the Cmd+U keyboard shortcut.\n\nPlease enable it in:\nSystem Settings → Privacy & Security → Accessibility"
                alert.alertStyle = .informational
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Skip for Now")

                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    // Open System Settings
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
        } else {
            NSLog("✅ Accessibility permissions granted")
        }
    }

    func registerGlobalHotKey() {
        // Guard against double registration
        if hotKeyRef != nil { return }

        var hotKeyID = EventHotKeyID()
        // Use simple numeric ID instead of FourCharCode
        hotKeyID.signature = 0x436C5542 // 'ClUB' as hex
        hotKeyID.id = 1

        // Cmd+U key code
        let keyCode: UInt32 = 32 // 'U' key
        let modifiers: UInt32 = UInt32(cmdKey)

        // Create event spec for hotkey
        var eventType = EventTypeSpec()
        eventType.eventClass = OSType(kEventClassKeyboard)
        eventType.eventKind = OSType(kEventHotKeyPressed)

        // Install event handler
        var handler: EventHandlerRef?
        let callback: EventHandlerUPP = { (nextHandler, event, userData) -> OSStatus in
            // Get the AppDelegate instance
            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()

            // Toggle popover. The Carbon hotkey is a C callback, not a Swift-concurrency
            // context, so it reaches the @MainActor delegate through `assumeIsolated` —
            // valid because it is dispatched onto the main thread.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { appDelegate.togglePopover() }
            }

            return noErr
        }

        // Install the handler
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, selfPtr, &handler)

        // Register the hotkey
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)

        if status == noErr {
            NSLog("✅ Registered Cmd+U hotkey successfully")
        } else {
            NSLog("❌ Failed to register hotkey, status: \(status)")
        }
    }

    func unregisterGlobalHotKey() {
        if let hotKey = hotKeyRef {
            UnregisterEventHotKey(hotKey)
            hotKeyRef = nil
            NSLog("🗑️ Unregistered Cmd+U hotkey")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        unregisterGlobalHotKey()
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            openPopover()
        }
    }

    @objc func handleClick() {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            // Right click - show menu
            let menu = NSMenu()
            let toggleItem = NSMenuItem(title: "Toggle Usage (⌘U)", action: #selector(togglePopover), keyEquivalent: "u")
            toggleItem.keyEquivalentModifierMask = .command
            menu.addItem(toggleItem)
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Quit ClaudeUsageBar", action: #selector(quitApp), keyEquivalent: "q"))
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            // Left click - toggle popover
            togglePopover()
        }
    }

    func openPopover() {
        if let button = statusItem.button {
            // §6: re-run discovery on popover open (throttled inside the store). This is
            // the store's local survey — it costs no upstream request.
            store.popoverWillOpen()
            // Force UI refresh by updating percentages
            DispatchQueue.main.async {
                self.usageManager.updatePercentages()
            }

            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

            // Add event monitor to detect clicks outside the popover
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                if self?.popover.isShown == true {
                    self?.closePopover()
                }
            }
        }
    }

    func closePopover() {
        popover.performClose(nil)

        // Remove event monitor
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}

// Main entry point
@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
