//
//  BuiltinDisplayToggleController.swift
//  BetterOSD
//

import CoreGraphics
import Foundation
import os

/// What the user asked for this session. Never persisted: disabling happens
/// only on an explicit action (recorded hotkey or menu item), and quitting
/// the app always re-enables the display.
enum BuiltinDisplayIntent: Equatable {
    case none
    case keepDisabled
}

enum BuiltinDisplayToggleOutcome: Equatable {
    case disabled
    case enabled
    /// No active external display — refusing keeps the user from blacking
    /// out the only screen.
    case refusedNoExternal
    /// No built-in display found (desktop Mac).
    case refusedUnavailable
    /// The SkyLight call failed (private API changed?).
    case failed
}

// Turns the built-in MacBook display fully off/on via the private SkyLight
// API while the lid stays open (cooling-friendly "clamshell").
//
// Safety model
// ------------
//   * Disable is user-initiated only — never from reconcile.
//   * Disable refuses when no external display is active.
//   * The display comes back "on any sneeze": last external gone, app quit,
//     or the user toggling it back.
//   * While intent == .keepDisabled, reconcile() re-applies the disable
//     after wake/display-reconfig resurrected the panel.
//
// Re-entrancy: applying a configuration triggers further reconfiguration
// events, so observers only *schedule* a debounced reconcile; reconcile is
// idempotent (desired == actual → no-op) and a circuit breaker gives up if
// WindowServer keeps resurrecting the panel anyway.
final class BuiltinDisplayToggleController {
    static let shared = BuiltinDisplayToggleController()

    /// Session-only. Drives the menu item title/state.
    private(set) var intent: BuiltinDisplayIntent = .none

    private let client: BuiltinDisplayControlling
    private let eventSource: DisplayEventSourcing
    private let hudStore: HUDDisplayStateStore
    private let reconcileDelay: TimeInterval
    private let safetyRetryDelays: [TimeInterval]
    private let applyCooldown: TimeInterval
    /// Reality poll while the user wants the panel off: reconfiguration
    /// flags proved unreliable (a removal event simply never arrived on one
    /// unplug), so the controller also re-checks the world on a timer.
    private let pollInterval: TimeInterval
    private var pollTask: Task<Void, Never>?
    private var lastReconcileDecision = ""
    private var reconcileTask: Task<Void, Never>?
    private var resurrectAttempts = 0
    // Safety-enable retry bookkeeping: a SkyLight enable in the zero-displays
    // state can report success without lighting the panel up.
    private var safetyRetryAttempts = 0
    private var safetyRetryTask: Task<Void, Never>?
    // Right after our own config change, CG flags stay stale for seconds
    // (online+active reported for a disabled panel) — ignore resurrect
    // observations during this window instead of fighting them (1001s).
    private var suppressResurrectUntil = Date.distantPast
    // Externals removed in the current reconfiguration storm. An unplugged
    // display lingers in the CG active list for seconds (a ghost that reads
    // exactly like a live external); without excluding them, the safety
    // re-enable never fires and macOS's own zero-display rescue gets
    // re-disabled by the resurrect path.
    private var ghostExternalIDs: Set<CGDirectDisplayID> = []
    // Externals observed while the panel was ON. At zero displays
    // WindowServer spawns a placeholder "display" (add+enabled+setMain) that
    // reads exactly like a real external in every CG list — the only reliable
    // tell is that placeholders only ever appear while the panel is off.
    // Display IDs are per-boot, so this stays in-memory.
    private var knownRealExternalIDs: Set<CGDirectDisplayID> = []
    private var isRunning = false

    /// Give-up threshold for repeated WindowServer resurrections.
    static let maxResurrectAttempts = 5

    /// Backoff ladder (seconds) for the safety-enable retry ladder.
    static let defaultSafetyRetryDelays: [TimeInterval] = [0.5, 1, 2, 4, 8]

    /// Reality-poll period while intent == .keepDisabled (seconds).
    static let defaultPollInterval: TimeInterval = 1

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.zhangyu.volume-hud",
        category: "BuiltinDisplay"
    )

    init(
        client: BuiltinDisplayControlling = SkyLightBuiltinDisplayClient(),
        eventSource: DisplayEventSourcing = BuiltinDisplayEventObserver(),
        hudStore: HUDDisplayStateStore = .shared,
        reconcileDelay: TimeInterval = 0.15,
        safetyRetryDelays: [TimeInterval] = BuiltinDisplayToggleController.defaultSafetyRetryDelays,
        applyCooldown: TimeInterval = BuiltinDisplayToggleController.defaultApplyCooldown,
        pollInterval: TimeInterval = BuiltinDisplayToggleController.defaultPollInterval
    ) {
        self.client = client
        self.eventSource = eventSource
        self.hudStore = hudStore
        self.reconcileDelay = reconcileDelay
        self.safetyRetryDelays = safetyRetryDelays
        self.applyCooldown = applyCooldown
        self.pollInterval = pollInterval
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        eventSource.start(
            onDisplayEvent: { [weak self] displayID, flags in
                self?.handleDisplayEvent(displayID: displayID, flags: flags)
            },
            onWake: { [weak self] in self?.scheduleReconcile() }
        )
        startRealityPoll()
        recoverPanelLeftOffIfNeeded()
    }

    /// Flags can get lost — poll the real world while the user wants the
    /// panel off. Reconcile is idempotent, so a poll that finds nothing
    /// changed costs a couple of CG calls.
    private func startRealityPoll() {
        guard pollInterval > 0, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(for: .seconds(self?.pollInterval ?? 1))
                guard Task.isCancelled == false, let self else { break }
                if self.intent == .keepDisabled {
                    self.reconcile()
                }
            }
        }
    }

    /// Reconfiguration bookkeeping: removals create ghosts (excluded from the
    /// "is an external present" check), additions clear them. Builtin-display
    /// events need no bookkeeping.
    private func handleDisplayEvent(displayID: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        if client.isBuiltinDisplay(displayID) {
            scheduleReconcile()
            return
        }

        if flags.contains(.removeFlag) {
            ghostExternalIDs.insert(displayID)
            if BuiltinDisplayLog.debugEnabled {
                Self.logger.info("external \(displayID) removed — ghosting it")
            }
        }
        if flags.contains(.addFlag) {
            ghostExternalIDs.remove(displayID)
        }
        scheduleReconcile()
    }

    /// Externals that are really present right now (ghosts and zero-displays
    /// placeholders excluded). While the panel is on, current externals are
    /// learned as real — that is the only moment a placeholder can't be in
    /// the list, which makes it the only trustworthy sample point.
    private var realExternalIDs: [CGDirectDisplayID] {
        let active = client.activeExternalDisplayIDs()
        // Drop ghosts that finally left the active list.
        ghostExternalIDs.formIntersection(Set(active))

        // Learning is only trustworthy while the user holds no disable
        // intent: at the unplug moment macOS rescues the panel (reads
        // online+active) while the placeholder is in the list — learning
        // then would certify the placeholder as a real external.
        if intent == .none,
           let id = client.builtinDisplayID(),
           client.isDisplayOnline(id), client.isDisplayActive(id) {
            let learned = Set(active).subtracting(knownRealExternalIDs)
            if learned.isEmpty == false {
                knownRealExternalIDs.formUnion(learned)
                if BuiltinDisplayLog.debugEnabled {
                    let learnedText = learned.map { String($0) }.joined(separator: ",")
                    Self.logger.info("learned real externals: \(learnedText, privacy: .public)")
                }
            }
        }

        // Without priors (fresh boot straight into a disabled panel) the list
        // minus ghosts is the best available answer.
        guard knownRealExternalIDs.isEmpty == false else {
            return active.filter { ghostExternalIDs.contains($0) == false }
        }
        return active.filter {
            ghostExternalIDs.contains($0) == false && knownRealExternalIDs.contains($0)
        }
    }

    /// The feature master switch was turned off: bring the panel back (if it
    /// is off for any reason) and forget any disable intent.
    func disableFeature() {
        intent = .none
        resurrectAttempts = 0
        if builtinPanelIsOff {
            if BuiltinDisplayLog.debugEnabled {
            Self.logger.info("feature disabled — re-enabling built-in display")
        }
            _ = apply(true, sessionScoped: false)
        }
    }

    /// True when the panel is disabled right now but this session holds no
    /// intent for it (app was killed while off, fresh launch). Only checked
    /// with the lid open — clamshell looks identical to a disabled panel.
    var builtinPanelIsOff: Bool {
        guard !client.isClamshellClosed(),
              let id = client.builtinDisplayID()
        else { return false }
        return !client.isDisplayOnline(id) && !client.isDisplayActive(id)
    }

    /// Safety net for the kill-while-off case: turning the display back ON
    /// needs no user action — only turning it off ever does.
    private func recoverPanelLeftOffIfNeeded() {
        guard builtinPanelIsOff else { return }
        if BuiltinDisplayLog.debugEnabled {
            Self.logger.info("built-in display found off at launch — re-enabling")
        }
        _ = apply(true, sessionScoped: false)
    }

    /// Re-enables the display synchronously and unregisters observers.
    /// Called from applicationWillTerminate — must not rely on the run loop
    /// spinning again (kCGConfigurePermanently does not revert on its own).
    func shutdown() {
        reconcileTask?.cancel()
        safetyRetryTask?.cancel()
        pollTask?.cancel()
        pollTask = nil
        eventSource.stop()
        isRunning = false
        guard intent == .keepDisabled else { return }
        intent = .none
        _ = apply(true, sessionScoped: false)
    }

    // MARK: - Toggle (hotkey + menu item)

    @discardableResult
    func toggle() -> BuiltinDisplayToggleOutcome {
        switch intent {
        case .none:
            guard let builtinID = client.builtinDisplayID() else {
                if BuiltinDisplayLog.debugEnabled {
                    Self.logger.info("refusing to disable: no built-in display found")
                }
                showHUD(.refusedUnavailable)
                return .refusedUnavailable
            }

            // Rescue: the panel is off but this session never asked for it
            // (killed app, fresh launch). One click turns it back on. In
            // clamshell the same "dropped from online" state is normal, so
            // the rescue must not fire there.
            if !client.isClamshellClosed(),
               !client.isDisplayOnline(builtinID),
               !client.isDisplayActive(builtinID) {
                if apply(true, sessionScoped: false) {
                    showHUD(.enabled)
                    return .enabled
                }
                Self.logger.error("rescue enable failed")
                showHUD(.failed)
                return .failed
            }

            guard realExternalIDs.isEmpty == false else {
                if BuiltinDisplayLog.debugEnabled {
                    Self.logger.info("refusing to disable: no active external display")
                }
                showHUD(.refusedNoExternal)
                return .refusedNoExternal
            }
            guard apply(false, sessionScoped: false) else {
                Self.logger.error("disable failed — SkyLight call did not succeed")
                showHUD(.failed)
                return .failed
            }
            intent = .keepDisabled
            resurrectAttempts = 0
            scheduleReconcile()
            showHUD(.disabled)
            return .disabled

        case .keepDisabled:
            guard apply(true, sessionScoped: false) else {
                // Keep the intent — reconcile retries the enable whenever a
                // display event lands, and the user can press again.
                Self.logger.error("enable failed — keeping intent, will retry on next display event")
                showHUD(.failed)
                return .failed
            }
            intent = .none
            resurrectAttempts = 0
            showHUD(.enabled)
            return .enabled
        }
    }

    // MARK: - Reconcile

    /// Debounced — bursts of reconfiguration events coalesce into one pass.
    func scheduleReconcile() {
        reconcileTask?.cancel()
        let delay = reconcileDelay
        reconcileTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard Task.isCancelled == false else { return }
            self?.reconcile()
        }
    }

    private func reconcile() {
        guard intent == .keepDisabled else { return }

        let realExternals = realExternalIDs
        let builtinID = client.builtinDisplayID()
        let online = builtinID.map { client.isDisplayOnline($0) } ?? false
        let active = builtinID.map { client.isDisplayActive($0) } ?? false
        // The reality poll calls this every second — debug-only, and only
        // when the decision changed.
        if BuiltinDisplayLog.debugEnabled {
            let idText = builtinID.map { String($0) } ?? "nil"
            let idsText = realExternals.map { String($0) }.joined(separator: ",")
            let decision = "ext=\(realExternals.count > 0) ids=\(idsText) ghosts=\(self.ghostExternalIDs.count) known=\(self.knownRealExternalIDs.count) id=\(idText) online=\(online) active=\(active) suppressed=\(Date() < self.suppressResurrectUntil)"
            if decision != lastReconcileDecision {
                lastReconcileDecision = decision
                Self.logger.info("reconcile: \(decision, privacy: .public)")
            }
        }

        guard realExternals.isEmpty == false else {
            // Safety: the last external is gone — the panel must come back.
            // Intent deliberately survives so the display re-disables when
            // an external appears again (mirrors the wake-up re-apply).
            resurrectAttempts = 0
            safetyEnable()
            return
        }

        // An external is present; the safety-retry ladder is done.
        safetyRetryTask?.cancel()
        safetyRetryAttempts = 0

        guard let builtinID else { return }
        guard online, active else {
            // Offline = disabled (or mid-transition) — settled.
            resurrectAttempts = 0
            return
        }

        // CG flags stay stale for seconds right after our own change — the
        // panel is not really resurrected, just the flags lagging behind.
        guard Date() >= suppressResurrectUntil else { return }

        // Genuinely resurrected (wake/reconfig) while the user wants it off.
        if apply(false, sessionScoped: false) {
            resurrectAttempts += 1
            if resurrectAttempts > Self.maxResurrectAttempts {
                giveUp()
            }
        } else {
            // A failing disable (mid-transition 1001s) must not turn the
            // 1 s reality poll into a hammer — one retry per window.
            suppressResurrectUntil = Date().addingTimeInterval(Self.failedApplyBackoff)
        }
    }

    /// The emergency enable must ALWAYS assert the SkyLight call, even when
    /// the panel already reads online (macOS's zero-displays rescue): the
    /// persisted display profile still says "disabled" — our disable was
    /// permanent — so the panel stays dark and any reconfiguration
    /// re-applies the profile. Only a successful enable rewrites it. Victory (and the
    /// intent clear) requires the call to succeed AND the panel online.
    private func safetyEnable() {
        safetyRetryTask?.cancel()

        let sessionScoped = safetyRetryAttempts >= 2
        let applied = apply(true, sessionScoped: sessionScoped)
        let online = client.builtinDisplayID().map { client.isDisplayOnline($0) } ?? false
        if BuiltinDisplayLog.debugEnabled {
            Self.logger.info("safety enable attempt \(self.safetyRetryAttempts)\(sessionScoped ? " (session)" : ""): applied=\(applied) panel online=\(online)")
        }

        if applied, online {
            safetyRetryAttempts = 0
            intent = .none
            if BuiltinDisplayLog.debugEnabled {
                Self.logger.info("safety: emergency enable verified — leaving the panel on")
            }
            return
        }

        guard safetyRetryAttempts < self.safetyRetryDelays.count else {
            Self.logger.error("safety enable did not take effect after \(self.safetyRetryDelays.count + 1) attempts")
            return
        }

        let delay = self.safetyRetryDelays[safetyRetryAttempts]
        safetyRetryAttempts += 1
        safetyRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard Task.isCancelled == false else { return }
            self?.reconcile()
        }
    }

    /// Cooldown after our own config change: CG flags lag behind for seconds.
    static let defaultApplyCooldown: TimeInterval = 3

    /// Pause after a failed re-disable (transition-window 1001s).
    static let failedApplyBackoff: TimeInterval = 5

    @discardableResult
    private func apply(_ enabled: Bool, sessionScoped: Bool) -> Bool {
        let ok = client.setBuiltinDisplayEnabled(enabled, sessionScoped: sessionScoped)
        if ok {
            suppressResurrectUntil = Date().addingTimeInterval(applyCooldown)
        }
        return ok
    }

    /// Circuit breaker: endless apply/resurrect ping-pong protection.
    private func giveUp() {
        Self.logger.error("built-in display keeps resurrecting — giving up, leaving it enabled")
        intent = .none
        resurrectAttempts = 0
        _ = apply(true, sessionScoped: false)
        showHUD(.failed)
    }

    // MARK: - HUD feedback

    private func showHUD(_ outcome: BuiltinDisplayToggleOutcome) {
        let state: HUDDisplayState
        switch outcome {
        case .disabled:
            state = HUDDisplayState(iconName: "display", level: 0, isMuted: true)
        case .enabled:
            state = HUDDisplayState(iconName: "display", level: 1, isMuted: false)
        case .refusedNoExternal, .refusedUnavailable, .failed:
            state = HUDDisplayState(iconName: "exclamationmark.triangle.fill", level: 0, isMuted: true)
        }
        hudStore.update(state)
    }

    // MARK: - Testing

    func reconcileForTesting() {
        reconcile()
    }

    func setIntentForTesting(_ intent: BuiltinDisplayIntent) {
        self.intent = intent
    }
}
