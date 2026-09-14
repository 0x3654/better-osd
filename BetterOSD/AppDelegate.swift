//
//  AppDelegate.swift
//  BetterOSD
//
//  Created by yu on 2025/9/23.
//

import AppKit
import Sparkle
import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate, SPUStandardUserDriverDelegate, UNUserNotificationCenterDelegate {
    private let osdWindowManager = BetterOSDWindowManager()
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: self
    )
    private let updateNotificationIdentifier = "BetterOSD.UpdateAvailable"
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private weak var builtinDisplayMenuItem: NSMenuItem?

    var automaticallyDownloadsUpdates: Bool {
        updaterController.updater.automaticallyDownloadsUpdates
    }

    var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        updaterController.updater.automaticallyDownloadsUpdates = enabled
    }

    func updater(_: SPUUpdater, willScheduleUpdateCheckAfterDelay _: TimeInterval) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else {
                return
            }

            UNUserNotificationCenter.current().requestAuthorization(options: [.badge, .alert, .sound]) { _, _ in}
        }
    }

    func standardUserDriverWillHandleShowingUpdate(
        _: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        NSApp.setActivationPolicy(.regular)

        guard !state.userInitiated else {
            return
        }

        NSApp.dockTile.badgeLabel = "1"
        postUpdateNotification(for: update)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate _: SUAppcastItem) {
        clearUpdateReminder()
    }

    func standardUserDriverWillFinishUpdateSession() {
        clearUpdateReminder()
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_: Notification) {
        NSMenuItem.disableAutoIcons()
        UNUserNotificationCenter.current().delegate = self
        _ = updaterController

        let currentShowInMenuBar = UserDefaults.standard.object(forKey: AppStorageKeys.showInMenuBar) as? Bool ?? true

        if currentShowInMenuBar {
            showStatusItem()
        }

        promptAccessibilityIfNeeded()
        restoreKeyRemappingIfNeeded()
        BuiltinDisplayToggleController.shared.start()
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        openSettings()
        return false
    }

    private func showStatusItem() {
        guard statusItem == nil else {
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            let customIcon = NSImage(systemSymbolName: "rectangle.center.inset.filled", accessibilityDescription: "Better OSD")
            customIcon?.size = NSSize(width: 16, height: 16)
            button.image = customIcon
            button.target = self
        }

        let menu = NSMenu()

        let settingsItem = NSMenuItem(
            title: NSLocalizedString("Settings", comment: ""),
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let updateItem = NSMenuItem(
            title: NSLocalizedString("Check for Updates", comment: ""),
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = updaterController
        menu.addItem(updateItem)

        menu.addItem(.separator())
        let builtinDisplayItem = NSMenuItem(
            title: NSLocalizedString("Turn Off Built-in Display", comment: ""),
            action: #selector(toggleBuiltinDisplay(_:)),
            keyEquivalent: ""
        )
        builtinDisplayItem.target = self
        menu.addItem(builtinDisplayItem)
        builtinDisplayMenuItem = builtinDisplayItem

        let quitItem = NSMenuItem(title:
            NSLocalizedString("Quit", comment: ""),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem?.menu = menu
    }

    @objc private func toggleBuiltinDisplay(_: NSMenuItem?) {
        BuiltinDisplayToggleController.shared.toggle()
        refreshBuiltinDisplayMenuItem()
    }

    private func refreshBuiltinDisplayMenuItem() {
        guard let item = builtinDisplayMenuItem else { return }
        let enabled = UserDefaults.standard.object(
            forKey: AppStorageKeys.builtinDisplayOffEnabled) as? Bool ?? false
        item.isHidden = !enabled
        guard enabled else { return }

        let controller = BuiltinDisplayToggleController.shared
        if controller.intent == .keepDisabled || controller.builtinPanelIsOff {
            item.title = NSLocalizedString("Turn On Built-in Display", comment: "")
            item.state = .on
        } else {
            item.title = NSLocalizedString("Turn Off Built-in Display", comment: "")
            item.state = .off
        }
    }

    // Re-applies hidutil F5/F6 remapping on every launch when the keyboard backlight
    // OSD is enabled with the standard assignment. Replaces the need for a separate
    // LaunchAgent — BetterOSD itself is already a login item.
    private func restoreKeyRemappingIfNeeded() {
        let enabled = UserDefaults.standard.object(forKey: AppStorageKeys.keyboardBacklightEnabled) as? Bool ?? false
        let mode = UserDefaults.standard.string(forKey: AppStorageKeys.keyboardBrightnessKeyMode) ?? ""
        guard enabled, mode == "f5f6" else { return }
        HIDUtilRemapper.applyF5F6Remapping()
    }

    private func promptAccessibilityIfNeeded() {
        let defaults = UserDefaults.standard

        if defaults.object(forKey: AppStorageKeys.accessibilityPrompted) == nil {
            defaults.set(true, forKey: AppStorageKeys.accessibilityPrompted)
            guard !MediaKeyMonitor.shared.hasAccessibilityPermission() else { return }

            NSApp.activate(ignoringOtherApps: true)
            MediaKeyMonitor.shared.requestAccessibilityPermission()
            MediaKeyMonitor.shared.startAccessibilityPolling()
        }
    }

    private func hideStatusItem() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let settingsView = SettingsView()
            let hostingView = NSHostingView(rootView: settingsView)

            settingsWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            settingsWindow?.titleVisibility = .hidden
            settingsWindow?.toolbar = NSToolbar()
            settingsWindow?.toolbarStyle = .unifiedCompact
            settingsWindow?.contentView = hostingView
            settingsWindow?.center()
            settingsWindow?.isReleasedWhenClosed = false
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateMenuBarVisibility(visible: Bool) {
        if visible {
            showStatusItem()
        } else {
            hideStatusItem()
        }
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.notification.request.identifier == updateNotificationIdentifier,
           response.actionIdentifier == UNNotificationDefaultActionIdentifier
        {
            updaterController.checkForUpdates(nil)
        }

        completionHandler()
    }

    func applicationWillTerminate(_: Notification) {
        // First: kCGConfigurePermanently does not revert on its own, so the
        // display must be re-enabled before anything tears the app down.
        BuiltinDisplayToggleController.shared.shutdown()
        osdWindowManager.stop()
        MediaKeyMonitor.shared.stop()
        VolumeMonitor.shared.stop()
    }

    private func postUpdateNotification(for update: SUAppcastItem) {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("Update Available", comment: "")
        content.body = String(format: NSLocalizedString("Version %@ is now available.", comment: ""), update.displayVersionString)

        let request = UNNotificationRequest(identifier: updateNotificationIdentifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func clearUpdateReminder() {
        NSApp.dockTile.badgeLabel = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [updateNotificationIdentifier])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [updateNotificationIdentifier])
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        refreshBuiltinDisplayMenuItem()
    }
}
