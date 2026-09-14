//
//  BuiltinDisplayEventObserver.swift
//  BetterOSD
//

import AppKit
import CoreGraphics
import Foundation
import os

/// Surfaces the two events the built-in display toggle reacts to: display
/// reconfigurations (cable pulled, monitor lost, lid-state changes) and wake
/// from sleep. Handlers always run on the MainActor.
///
/// Reconfigurations carry the changed display and summary flags (add/remove/
/// begin/…) — the controller uses removals/additions to tell a real external
/// from the ghost an unplugged display leaves in the CG lists for seconds.
protocol DisplayEventSourcing: AnyObject {
    func start(
        onDisplayEvent: @escaping (_ displayID: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags) -> Void,
        onWake: @escaping () -> Void
    )
    func stop()
}

final class BuiltinDisplayEventObserver: DisplayEventSourcing {
    private var onDisplayEvent: ((CGDirectDisplayID, CGDisplayChangeSummaryFlags) -> Void)?
    private var onWake: (() -> Void)?
    private var wakeObserver: NSObjectProtocol?
    private var isRunning = false

    // The C callback may arrive on any thread; buffer events under a lock and
    // drain them in order on the MainActor so add/remove bookkeeping can
    // never race a reconcile pass.
    private nonisolated(unsafe) var pendingEvents: [(CGDirectDisplayID, CGDisplayChangeSummaryFlags)] = []
    private let eventLock = NSLock()

    func start(
        onDisplayEvent: @escaping (_ displayID: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags) -> Void,
        onWake: @escaping () -> Void
    ) {
        guard !isRunning else { return }
        isRunning = true
        self.onDisplayEvent = onDisplayEvent
        self.onWake = onWake

        // Never touch display configuration from inside this callback — the
        // observer only buffers and schedules async MainActor work.
        let status = CGDisplayRegisterReconfigurationCallback(
            Self.reconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        if status != .success {
            Self.logger.error("CGDisplayRegisterReconfigurationCallback failed: \(status.rawValue)")
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onWake?()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        CGDisplayRemoveReconfigurationCallback(
            Self.reconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        onDisplayEvent = nil
        onWake = nil

        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    private static let logger = os.Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.zhangyu.volume-hud",
        category: "BuiltinDisplay"
    )

    private static let reconfigurationCallback: CGDisplayReconfigurationCallBack = { displayID, flags, userInfo in
        guard let userInfo else { return }
        let observer = Unmanaged<BuiltinDisplayEventObserver>.fromOpaque(userInfo).takeUnretainedValue()
        observer.enqueueEvent(displayID: displayID, flags: flags)
    }

    /// Called from the C callback's thread — buffer, then hop to the MainActor.
    private nonisolated func enqueueEvent(
        displayID: CGDirectDisplayID,
        flags: CGDisplayChangeSummaryFlags
    ) {
        eventLock.lock()
        pendingEvents.append((displayID, flags))
        eventLock.unlock()

        Task { @MainActor [weak self] in
            self?.drainEvents()
        }
    }

    private func drainEvents() {
        eventLock.lock()
        let events = pendingEvents
        pendingEvents = []
        eventLock.unlock()

        for event in events {
            if BuiltinDisplayLog.debugEnabled {
                Self.logger.info("display event: id=\(event.0) flags=\(event.1.rawValue)")
            }
            onDisplayEvent?(event.0, event.1)
        }
    }
}
