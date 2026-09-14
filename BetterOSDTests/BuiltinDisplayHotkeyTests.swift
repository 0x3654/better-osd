//
//  BuiltinDisplayHotkeyTests.swift
//  BetterOSDTests
//

import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import BetterOSD

/// The test host is the real app sharing the user's defaults domain — every
/// key the tests touch is snapshotted on creation and restored on release,
/// or a test run silently wipes the user's recorded combo and feature switch.
/// Deliberately nonisolated: UserDefaults is thread-safe and the class must
/// restore from its deinit.
private final class DefaultsSnapshot {
    private let keys: [String]
    private var saved: [String: Any] = [:]
    private var restored = false

    init(keys: [String]) {
        self.keys = keys
        let defaults = UserDefaults.standard
        for key in keys where defaults.object(forKey: key) != nil {
            saved[key] = defaults.object(forKey: key)
        }
    }

    func restore() {
        guard restored == false else { return }
        restored = true
        let defaults = UserDefaults.standard
        for key in keys {
            if let value = saved[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    deinit {
        restore()
    }
}

@Suite(.serialized)
@MainActor
struct BuiltinDisplayHotkeyTests {
    private static let csaFlags = CGEventFlags(
        rawValue: CGEventFlags.maskControl.rawValue
            | CGEventFlags.maskShift.rawValue
            | CGEventFlags.maskAlternate.rawValue
    )

    private let defaultsSnapshot = DefaultsSnapshot(keys: [
        AppStorageKeys.builtinDisplayOffEnabled,
        AppStorageKeys.builtinDisplayToggleKeyCode,
        AppStorageKeys.builtinDisplayToggleModifiers
    ])

    private func makeMonitor(
        toggler: @escaping () -> BuiltinDisplayToggleOutcome = { .disabled }
    ) -> MediaKeyMonitor {
        MediaKeyMonitor(
            volumeKeyController: HotkeyFakeVolumeKeyHandler(),
            brightnessKeyController: HotkeyFakeBrightnessKeyHandler(),
            builtinDisplayToggler: toggler
        )
    }

    private func recordCombo(_ keyCode: Int64 = 2, _ modifiers: UInt64 = Self.csaFlags.rawValue) {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: AppStorageKeys.builtinDisplayOffEnabled)
        defaults.set(Int(keyCode), forKey: AppStorageKeys.builtinDisplayToggleKeyCode)
        defaults.set(Int(modifiers), forKey: AppStorageKeys.builtinDisplayToggleModifiers)
    }

    private func clearCombo() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: AppStorageKeys.builtinDisplayOffEnabled)
        defaults.removeObject(forKey: AppStorageKeys.builtinDisplayToggleKeyCode)
        defaults.removeObject(forKey: AppStorageKeys.builtinDisplayToggleModifiers)
    }

    private func keyDownEvent(keyCode: Int64, flags: CGEventFlags, characters: String? = nil) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true)!
        event.flags = flags
        if let characters {
            event.keyboardSetUnicodeString(
                stringLength: characters.utf16.count,
                unicodeString: Array(characters.utf16)
            )
        }
        return event
    }

    // MARK: - Combo matching

    @Test
    func recordedComboMatchesExactly() {
        recordCombo()
        defer { clearCombo() }

        let monitor = makeMonitor()

        #expect(monitor.matchesBuiltinDisplayToggle(keyCode: 2, flags: Self.csaFlags))
        // Extra modifier held → no match (typing stays safe).
        #expect(!monitor.matchesBuiltinDisplayToggle(
            keyCode: 2,
            flags: Self.csaFlags.union(.maskCommand)
        ))
        #expect(!monitor.matchesBuiltinDisplayToggle(keyCode: 0, flags: Self.csaFlags))
        #expect(!monitor.matchesBuiltinDisplayToggle(keyCode: 2, flags: []))
    }

    @Test
    func unconfiguredMatchesNothing() {
        clearCombo()
        let monitor = makeMonitor()

        #expect(!monitor.matchesBuiltinDisplayToggle(keyCode: 2, flags: Self.csaFlags))
    }

    @Test
    func featureDisabledByDefaultCatchesNothing() {
        clearCombo()
        let defaults = UserDefaults.standard
        defaults.set(Int(2), forKey: AppStorageKeys.builtinDisplayToggleKeyCode)
        defaults.set(Int(Self.csaFlags.rawValue), forKey: AppStorageKeys.builtinDisplayToggleModifiers)
        defer {
            defaults.removeObject(forKey: AppStorageKeys.builtinDisplayToggleKeyCode)
            defaults.removeObject(forKey: AppStorageKeys.builtinDisplayToggleModifiers)
        }

        let monitor = makeMonitor()

        // Combo recorded but the master switch is off (default) — no match.
        #expect(!monitor.matchesBuiltinDisplayToggle(keyCode: 2, flags: Self.csaFlags))
    }

    @Test
    func comboKeyConsumesAndToggles() {
        recordCombo()
        defer { clearCombo() }

        var outcomes: [BuiltinDisplayToggleOutcome] = []
        let monitor = makeMonitor(toggler: {
            outcomes.append(.disabled)
            return .disabled
        })

        let consumed = monitor.handleKeyDownForTesting(keyDownEvent(keyCode: 2, flags: Self.csaFlags))
        let passthrough = monitor.handleKeyDownForTesting(keyDownEvent(keyCode: 2, flags: []))

        #expect(consumed == nil)
        #expect(passthrough != nil)
        #expect(outcomes == [.disabled])
    }

    // MARK: - Recording

    @Test
    func recordingCapturesComboAndConsumesIt() {
        let monitor = makeMonitor()
        var recorded: [MediaKeyMonitor.RecordedHotkey] = []
        monitor.startRecording { recorded.append($0) }

        let consumed = monitor.handleKeyDownForTesting(keyDownEvent(keyCode: 2, flags: Self.csaFlags, characters: "d"))

        #expect(consumed == nil)
        #expect(recorded == [.keyCombo(keyCode: 2, modifierFlags: Self.csaFlags.rawValue, label: "⌃⇧⌥D")])
    }

    @Test
    func recordingPassesThroughBareKeys() {
        let monitor = makeMonitor()
        var recorded: [MediaKeyMonitor.RecordedHotkey] = []
        monitor.startRecording { recorded.append($0) }

        // No modifier → typed through, recording stays armed.
        let passthrough = monitor.handleKeyDownForTesting(keyDownEvent(keyCode: 2, flags: []))
        #expect(passthrough != nil)
        #expect(recorded.isEmpty)
    }

    @Test
    func recordingEscapeCancels() {
        let monitor = makeMonitor()
        var recorded: [MediaKeyMonitor.RecordedHotkey] = []
        monitor.startRecording { recorded.append($0) }

        let consumed = monitor.handleKeyDownForTesting(keyDownEvent(keyCode: 53, flags: .maskCommand))

        #expect(consumed == nil)
        #expect(recorded == [.cancelled])
    }

    // MARK: - Label

    @Test
    func comboLabelFormatting() {
        // Key name from the keycode map — even with option-composed garbage
        // (⌥D produces "∂") or no unicode at all.
        #expect(MediaKeyMonitor.comboLabel(keyCode: 2, modifierFlags: Self.csaFlags.rawValue, characters: "∂") == "⌃⇧⌥D")
        #expect(MediaKeyMonitor.comboLabel(keyCode: 2, modifierFlags: Self.csaFlags.rawValue, characters: nil) == "⌃⇧⌥D")
        #expect(MediaKeyMonitor.comboLabel(keyCode: 49, modifierFlags: CGEventFlags.maskCommand.rawValue, characters: " ") == "⌘Space")
        #expect(MediaKeyMonitor.comboLabel(keyCode: 300, modifierFlags: CGEventFlags.maskCommand.rawValue, characters: nil) == "⌘Key 300")
    }

    // MARK: - Toggle case routing

    @Test
    func toggleKeyConsumesAndCallsToggler() {
        var outcomes: [BuiltinDisplayToggleOutcome] = []
        let monitor = makeMonitor(toggler: {
            outcomes.append(.disabled)
            return .disabled
        })

        let result = monitor.handleMediaKeyForTesting(.builtinDisplayToggle, modifiers: [])

        #expect(result == .consumed(didChange: true))
        #expect(outcomes == [.disabled])
    }

    @Test
    func refusedToggleStillConsumes() {
        var outcomes: [BuiltinDisplayToggleOutcome] = []
        let monitor = makeMonitor(toggler: {
            outcomes.append(.refusedNoExternal)
            return .refusedNoExternal
        })

        let result = monitor.handleMediaKeyForTesting(.builtinDisplayToggle, modifiers: [])

        #expect(result == .consumed(didChange: false))
        #expect(outcomes == [.refusedNoExternal])
    }
}

@MainActor
private final class HotkeyFakeVolumeKeyHandler: VolumeKeyHandling {
    func handle(
        _: MediaKeyMonitor.MediaKey,
        fineStep _: Bool,
        invertFeedback _: Bool
    ) -> MediaKeyHandlingResult {
        .passThrough
    }
}

@MainActor
private final class HotkeyFakeBrightnessKeyHandler: BrightnessKeyHandling {
    var currentState: BrightnessState = BrightnessState(brightness: 0)

    func handle(_: MediaKeyMonitor.MediaKey, fineStep _: Bool) -> MediaKeyHandlingResult {
        .passThrough
    }

    func handle(
        _: MediaKeyMonitor.MediaKey,
        fineStep _: Bool,
        targetDisplayID _: CGDirectDisplayID
    ) -> MediaKeyHandlingResult {
        .passThrough
    }
}
