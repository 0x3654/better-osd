//
//  BuiltinDisplayToggleControllerTests.swift
//  BetterOSDTests
//

import CoreGraphics
import Foundation
import Testing
@testable import BetterOSD

@Suite(.serialized)
@MainActor
struct BuiltinDisplayToggleControllerTests {
    private func makeController(
        client: FakeBuiltinDisplayClient = FakeBuiltinDisplayClient(),
        eventSource: FakeDisplayEventSource = FakeDisplayEventSource(),
        reconcileDelay: TimeInterval = 0,
        safetyRetryDelays: [TimeInterval] = [],
        pollInterval: TimeInterval = 0
    ) -> (BuiltinDisplayToggleController, FakeBuiltinDisplayClient, FakeDisplayEventSource) {
        let controller = BuiltinDisplayToggleController(
            client: client,
            eventSource: eventSource,
            hudStore: HUDDisplayStateStore(initialState: .defaultVolumePlaceholder),
            reconcileDelay: reconcileDelay,
            safetyRetryDelays: safetyRetryDelays,
            applyCooldown: 0,
            pollInterval: pollInterval
        )
        return (controller, client, eventSource)
    }

    // MARK: - Toggle

    @Test
    func toggleRefusesWhenNoExternalDisplay() {
        let (controller, client, _) = makeController()
        client.activeExternalIDs = []

        let outcome = controller.toggle()

        #expect(outcome == .refusedNoExternal)
        #expect(client.setArguments.isEmpty)
        #expect(controller.intent == .none)
    }

    @Test
    func toggleRefusesWhenNoBuiltinFound() {
        let (controller, client, _) = makeController()
        client.builtinID = nil

        let outcome = controller.toggle()

        #expect(outcome == .refusedUnavailable)
        #expect(client.setArguments.isEmpty)
        #expect(controller.intent == .none)
    }

    @Test
    func toggleRescuesPanelLeftOff() {
        let (controller, client, _) = makeController()
        client.builtinOnline = false
        client.builtinActive = false

        let outcome = controller.toggle()

        // Fresh session, panel already off — one click turns it back on.
        #expect(outcome == .enabled)
        #expect(client.setArguments == [true])
        #expect(controller.intent == .none)
    }

    @Test
    func rescueNotAttemptedInClamshell() {
        let (controller, client, _) = makeController()
        client.builtinOnline = false
        client.builtinActive = false
        client.clamshellClosed = true

        let outcome = controller.toggle()

        // Clamshell looks identical to "disabled" — no rescue; the click
        // takes the normal disable path instead.
        #expect(outcome == .disabled)
        #expect(client.setArguments == [false])
        #expect(controller.intent == .keepDisabled)
    }

    @Test
    func toggleEnableFailureKeepsIntent() {
        let (controller, client, _) = makeController()
        client.setResults = [true, false]

        _ = controller.toggle()
        let outcome = controller.toggle()

        #expect(outcome == .failed)
        #expect(controller.intent == .keepDisabled)
    }

    @Test
    func launchRecoversPanelLeftOff() {
        let (_, client, eventSource) = makeController()
        client.builtinOnline = false
        client.builtinActive = false

        let controller = BuiltinDisplayToggleController(
            client: client,
            eventSource: eventSource,
            hudStore: HUDDisplayStateStore(initialState: .defaultVolumePlaceholder),
            reconcileDelay: 0
        )
        controller.start()

        #expect(client.setArguments == [true])
    }

    @Test
    func toggleDisablesWhenExternalPresent() {
        let store = HUDDisplayStateStore(initialState: .defaultVolumePlaceholder)
        let client = FakeBuiltinDisplayClient()
        let controller = BuiltinDisplayToggleController(
            client: client,
            eventSource: FakeDisplayEventSource(),
            hudStore: store,
            reconcileDelay: 0,
            applyCooldown: 0
        )

        let outcome = controller.toggle()

        #expect(outcome == .disabled)
        #expect(client.setArguments == [false])
        #expect(controller.intent == .keepDisabled)
        #expect(store.current == HUDDisplayState(iconName: "display", level: 0, isMuted: true))
    }

    @Test
    func toggleReenablesOnSecondToggle() {
        let (controller, client, _) = makeController()

        controller.toggle()
        let outcome = controller.toggle()

        #expect(outcome == .enabled)
        #expect(client.setArguments == [false, true])
        #expect(controller.intent == .none)
    }

    @Test
    func toggleLeavesIntentCleanOnFailure() {
        let (controller, client, _) = makeController()
        client.setResults = [false]

        let outcome = controller.toggle()

        #expect(outcome == .failed)
        #expect(client.setArguments == [false])
        #expect(controller.intent == .none)
    }

    // MARK: - Reconcile

    @Test
    func reconcileReappliesDisableAfterResurrection() {
        let (controller, client, _) = makeController()
        controller.setIntentForTesting(.keepDisabled)
        client.activeExternalIDs = [2]
        client.builtinActive = true

        controller.reconcileForTesting()

        #expect(client.setArguments == [false])
        #expect(controller.intent == .keepDisabled)
    }

    @Test
    func reconcileReenablesWhenLastExternalGone() {
        let (controller, client, _) = makeController()
        controller.setIntentForTesting(.keepDisabled)
        client.activeExternalIDs = []
        client.builtinOnline = false
        client.builtinActive = false

        controller.reconcileForTesting()

        #expect(client.setArguments == [true])
        // Intent survives the safety re-enable…
        #expect(controller.intent == .keepDisabled)
    }

    @Test
    func reconcileReDisablesWhenExternalReturns() {
        let (controller, client, _) = makeController()
        controller.setIntentForTesting(.keepDisabled)

        client.activeExternalIDs = []
        client.builtinOnline = false
        controller.reconcileForTesting()

        client.activeExternalIDs = [2]
        client.builtinOnline = true
        client.builtinActive = true
        controller.reconcileForTesting()

        // …so an external coming back re-disables the panel.
        #expect(client.setArguments == [true, false])
        #expect(controller.intent == .keepDisabled)
    }

    @Test
    func safetyEnableRetriesWhilePanelStaysDark() async throws {
        let (controller, client, _) = makeController(safetyRetryDelays: [0.05, 0.05])
        controller.setIntentForTesting(.keepDisabled)
        client.activeExternalIDs = []
        client.builtinOnline = false
        client.builtinActive = false
        // The SkyLight call keeps "succeeding" while the panel stays dark.

        controller.reconcileForTesting()
        try await Task.sleep(for: .seconds(0.4))

        // First attempt + two retries, then the ladder is exhausted.
        #expect(client.setArguments.count == 3)
        try await Task.sleep(for: .seconds(0.2))
        #expect(client.setArguments.count == 3)
    }

    @Test
    func safetyRetryStopsWhenExternalReturns() async throws {        let (controller, client, _) = makeController(safetyRetryDelays: [0.2])
        controller.setIntentForTesting(.keepDisabled)
        client.activeExternalIDs = []
        client.builtinOnline = false
        client.builtinActive = false

        controller.reconcileForTesting()

        // First pass: one safety enable, retry armed.
        #expect(client.setArguments == [true])

        client.activeExternalIDs = [2]
        client.builtinOnline = true
        client.builtinActive = true
        try await Task.sleep(for: .seconds(0.5))

        // The pending retry turned into a normal reconcile: intent still
        // wants the panel off, so it re-disables instead of retrying enable.
        #expect(client.setArguments == [true, false])
    }

    @Test
    func reconcileNoopWithoutIntent() {
        let (controller, client, _) = makeController()
        controller.setIntentForTesting(.none)
        client.activeExternalIDs = [2]
        client.builtinActive = true

        controller.reconcileForTesting()

        #expect(client.setArguments.isEmpty)
    }

    @Test
    func reconcileSettlesWhenAlreadyDisabled() {
        let (controller, client, _) = makeController()
        controller.setIntentForTesting(.keepDisabled)
        client.builtinActive = false

        controller.reconcileForTesting()

        #expect(client.setArguments.isEmpty)
    }

    @Test
    func circuitBreakerGivesUpAfterRepeatedResurrections() {
        let (controller, client, _) = makeController()
        controller.setIntentForTesting(.keepDisabled)
        client.activeExternalIDs = [2]
        client.builtinActive = true // never settles — fake "resurrection"

        for _ in 0 ... BuiltinDisplayToggleController.maxResurrectAttempts {
            controller.reconcileForTesting()
        }

        #expect(controller.intent == .none)
        #expect(client.setArguments.last == true) // give-up re-enables
    }

    @Test
    func shutdownReenablesAndStops() {
        let (controller, client, eventSource) = makeController()
        controller.toggle()

        controller.shutdown()

        // toggle applied false, shutdown re-enables with true.
        #expect(client.setArguments == [false, true])
        #expect(controller.intent == .none)
        #expect(eventSource.stopCalled)
    }

    @Test
    func realityPollRescuesPanelWhenFlagsNeverArrive() async throws {
        // The unplug sends no removal event at all — the poll still notices.
        let (controller, client, _) = makeController(pollInterval: 0.05)
        controller.start()
        controller.setIntentForTesting(.keepDisabled)
        client.activeExternalIDs = [2]
        client.builtinOnline = false
        client.builtinActive = false

        // "Unplug": the external leaves with no event delivered.
        client.activeExternalIDs = []
        try await Task.sleep(for: .seconds(0.4))

        #expect(client.setArguments.contains(true))
        controller.shutdown()
    }

    @Test
    func zeroDisplaysPlaceholderDoesNotCountAsExternal() async throws {
        let (controller, client, eventSource) = makeController(reconcileDelay: 0.05)
        controller.start()

        // Panel on + real Dell present → the Dell is learned as real.
        client.builtinOnline = true
        client.builtinActive = true
        client.activeExternalIDs = [2]
        let outcome = controller.toggle()
        #expect(outcome == .disabled)

        // Cable out: WindowServer spawns a placeholder external (id 7) that
        // is online+active in every CG list — it must not block the safety.
        client.activeExternalIDs = [7]
        client.builtinOnline = false
        client.builtinActive = false
        eventSource.onDisplayEvent?(7, .addFlag)
        try await Task.sleep(for: .seconds(0.3))

        #expect(client.setArguments.dropFirst().contains(true))

        // Real Dell replugged (still known-real) → panel re-disables.
        client.activeExternalIDs = [2]
        client.builtinOnline = true
        client.builtinActive = true
        eventSource.onDisplayEvent?(2, .addFlag)
        try await Task.sleep(for: .seconds(0.3))

        #expect(client.setArguments.last == false)
        controller.shutdown()
    }

    @Test
    func emergencyRescueIsLeftOnAndPlaceholderNotLearned() async throws {
        // Exact regression of the 2026-09-14 log: unplug spawns a
        // placeholder AND macOS rescues the panel in the same storm; the
        // placeholder must not be learned, the rescue must not be fought.
        let (controller, client, eventSource) = makeController(reconcileDelay: 0.05)
        controller.start()

        // Learn the real Dell while the panel is on, then disable.
        client.activeExternalIDs = [2]
        #expect(controller.toggle() == .disabled)

        // Unplug storm: Dell gone, placeholder id 8 in the list, macOS
        // itself brought the panel back (online+active).
        client.activeExternalIDs = [8]
        client.builtinOnline = true
        client.builtinActive = true
        eventSource.onDisplayEvent?(8, .addFlag)
        try await Task.sleep(for: .seconds(0.3))

        // The enable is asserted even though the panel reads online (the
        // persisted profile must be overwritten) and the intent is cleared.
        #expect(controller.intent == .none)
        #expect(client.setArguments == [false, true])

        controller.shutdown()
    }

    // MARK: - Ghost externals (unplug leaves the CG list stale for seconds)

    @Test
    func ghostExclusionPreventsReDisableAfterUnplug() async throws {
        let (controller, client, eventSource) = makeController(reconcileDelay: 0.05)
        controller.start()
        controller.setIntentForTesting(.keepDisabled)
        // Cable out, but the unplugged external still reads active (ghost);
        // the panel is online (macOS's own zero-display rescue).
        client.activeExternalIDs = [2]
        client.builtinOnline = true
        client.builtinActive = true

        eventSource.onDisplayEvent?(2, .removeFlag)
        try await Task.sleep(for: .seconds(0.3))

        // Without ghost exclusion the resurrect path would re-disable the
        // rescued panel; with it the safety branch asserts the enable (the
        // persisted profile still says "disabled") and clears the intent.
        #expect(client.setArguments == [true])
        #expect(controller.intent == .none)

        controller.shutdown()
    }

    @Test
    func replugClearsGhostAndReDisables() async throws {
        let (controller, client, eventSource) = makeController(reconcileDelay: 0.05)
        controller.start()
        controller.setIntentForTesting(.keepDisabled)
        client.activeExternalIDs = [2]
        client.builtinOnline = true
        client.builtinActive = true

        eventSource.onDisplayEvent?(2, .addFlag)
        try await Task.sleep(for: .seconds(0.3))

        // A real external is back and the user still wants the panel off.
        #expect(client.setArguments == [false])
        controller.shutdown()
    }

    // MARK: - Event sources (async — debounced reconcile)

    @Test
    func displayAndWakeEventsTriggerOneDebouncedReconcile() async throws {
        let (controller, client, eventSource) = makeController(reconcileDelay: 0.05)
        controller.setIntentForTesting(.keepDisabled)
        client.activeExternalIDs = [2]
        client.builtinActive = true
        controller.start()

        eventSource.onDisplayEvent?(1, [])
        eventSource.onDisplayEvent?(1, [])
        eventSource.onWake?()
        eventSource.onDisplayEvent?(1, [])
        eventSource.onDisplayEvent?(1, [])

        try await Task.sleep(for: .seconds(0.4))

        #expect(client.setArguments == [false])
        controller.shutdown()
    }
}

// MARK: - Fakes

@MainActor
private final class FakeBuiltinDisplayClient: BuiltinDisplayControlling {
    var builtinID: CGDirectDisplayID? = 1
    var activeExternalIDs: [CGDirectDisplayID] = [2]
    var builtinOnline = true
    var builtinActive = true
    var clamshellClosed = false
    /// Per-call success script; empty queue means "always succeed".
    var setResults: [Bool] = []
    private(set) var setArguments: [Bool] = []

    func builtinDisplayID() -> CGDirectDisplayID? { builtinID }

    func isDisplayActive(_: CGDirectDisplayID) -> Bool { builtinActive }

    func isDisplayOnline(_: CGDirectDisplayID) -> Bool { builtinOnline }

    func activeExternalDisplayIDs() -> [CGDirectDisplayID] { activeExternalIDs }

    func isBuiltinDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        displayID == builtinID
    }

    func isClamshellClosed() -> Bool { clamshellClosed }

    @discardableResult
    func setBuiltinDisplayEnabled(_ enabled: Bool, sessionScoped: Bool = false) -> Bool {
        setArguments.append(enabled)
        if setResults.isEmpty { return true }
        return setResults.removeFirst()
    }
}

@MainActor
private final class FakeDisplayEventSource: DisplayEventSourcing {
    private(set) var stopCalled = false
    var onDisplayEvent: ((CGDirectDisplayID, CGDisplayChangeSummaryFlags) -> Void)?
    var onWake: (() -> Void)?

    func start(
        onDisplayEvent: @escaping (CGDirectDisplayID, CGDisplayChangeSummaryFlags) -> Void,
        onWake: @escaping () -> Void
    ) {
        self.onDisplayEvent = onDisplayEvent
        self.onWake = onWake
    }

    func stop() {
        stopCalled = true
    }
}
