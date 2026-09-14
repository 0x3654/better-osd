//
//  BuiltinDisplayClient.swift
//  BetterOSD
//

import CoreGraphics
import Darwin
import Foundation
import IOKit
import os

/// Hardware truth + the private SkyLight call that fully enables/disables the
/// built-in display. A disabled display disappears from the WindowServer
/// desktop — windows, cursor, Dock and Spaces treat it as absent, and the
/// panel goes dark — which is exactly the "lid open for cooling, screen off"
/// clamshell-with-open-lid state.
protocol BuiltinDisplayControlling: AnyObject {
    /// The built-in display ID, however deeply it is buried right now: online
    /// list first; a SkyLight-disabled panel drops out of that list entirely
    /// on macOS 26, so the private CGS display list is the second stop; an
    /// in-memory/persisted cache is the last resort. Nil on Macs without a
    /// built-in panel.
    func builtinDisplayID() -> CGDirectDisplayID?
    func isDisplayActive(_ displayID: CGDirectDisplayID) -> Bool
    /// False for a display that is currently disabled (dropped from online).
    func isDisplayOnline(_ displayID: CGDirectDisplayID) -> Bool
    /// Active non-builtin displays (virtual/AirPlay included). NB: a just-
    /// unplugged display lingers here for seconds — callers combine this
    /// with the reconfiguration add/remove events to tell ghosts apart.
    func activeExternalDisplayIDs() -> [CGDirectDisplayID]
    func isBuiltinDisplay(_ displayID: CGDirectDisplayID) -> Bool
    /// Lid closed (clamshell). The dropped-from-online panel state looks
    /// identical to a disabled one, so rescue paths must not fire in clamshell.
    func isClamshellClosed() -> Bool
    @discardableResult
    func setBuiltinDisplayEnabled(_ enabled: Bool, sessionScoped: Bool) -> Bool
}

// Verbose BuiltinDisplay info logging — OFF by default (the reconcile poll
// is chatty). Diagnosing: launch with `-betterosd-display-debug` or set the
// `builtinDisplayDebugLogs` default. Errors always log.
enum BuiltinDisplayLog {
    static let debugEnabled: Bool = {
        ProcessInfo.processInfo.arguments.contains("-betterosd-display-debug")
            || UserDefaults.standard.bool(forKey: "builtinDisplayDebugLogs")
    }()
}

// Resolves CGSConfigureDisplayEnabled from the private SkyLight framework —
// the same call macOS itself uses for clamshell-mode display off. Structurally
// a sibling of DisplayServicesBrightnessClient (dlopen + dlsym + @convention(c)).
final class SkyLightBuiltinDisplayClient: BuiltinDisplayControlling {
    private typealias ConfigureDisplayEnabled = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
    private typealias GetDisplayList = @convention(c) (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError

    private let frameworkPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    private nonisolated(unsafe) var handle: UnsafeMutableRawPointer?
    private var configureDisplayEnabled: ConfigureDisplayEnabled?
    private var getDisplayList: GetDisplayList?

    /// Last ID we managed to resolve — survives the panel going dark.
    private var lastKnownBuiltinID: CGDirectDisplayID?

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.zhangyu.volume-hud",
        category: "BuiltinDisplay"
    )

    func builtinDisplayID() -> CGDirectDisplayID? {
        if let online = onlineDisplayIDs().first(where: { CGDisplayIsBuiltin($0) != 0 }) {
            remember(online)
            return online
        }

        // A disabled panel is gone from the CG online list on macOS 26 —
        // WindowServer still tracks it in the private CGS list.
        if let cgs = cgsDisplayIDs().first(where: { CGDisplayIsBuiltin($0) != 0 }) {
            remember(cgs)
            return cgs
        }

        if let lastKnownBuiltinID {
            return lastKnownBuiltinID
        }
        if let persisted = UserDefaults.standard.object(forKey: AppStorageKeys.builtinDisplayKnownID) as? Int,
           persisted > 0 {
            return CGDirectDisplayID(persisted)
        }

        Self.logger.error("could not resolve built-in display ID anywhere")
        return nil
    }

    func isDisplayActive(_ displayID: CGDirectDisplayID) -> Bool {
        CGDisplayIsActive(displayID) != 0
    }

    func isDisplayOnline(_ displayID: CGDirectDisplayID) -> Bool {
        CGDisplayIsOnline(displayID) != 0
    }

    /// Last fingerprint logged — placeholders and ghosts churn; a one-line
    /// snapshot on every change makes them tell apart in the log.
    private var lastLoggedExternals: [CGDirectDisplayID] = []

    func activeExternalDisplayIDs() -> [CGDirectDisplayID] {
        // Online matters: an unplugged display leaves the online list long
        // before (if ever) it leaves the active one — the ghost filter.
        let ids = activeDisplayIDs().filter { CGDisplayIsBuiltin($0) == 0 && CGDisplayIsOnline($0) != 0 }
        if BuiltinDisplayLog.debugEnabled, ids != lastLoggedExternals {
            lastLoggedExternals = ids
            let fingerprints = ids.map { id in
                let bounds = CGDisplayBounds(id)
                return "id\(id):v\(CGDisplayVendorNumber(id))m\(CGDisplayModelNumber(id))s\(CGDisplaySerialNumber(id))mir\(CGDisplayMirrorsDisplay(id))\(Int(bounds.width))x\(Int(bounds.height))"
            }.joined(separator: " ")
            Self.logger.info("externals: \(fingerprints, privacy: .public)")
        }
        return ids
    }

    func isBuiltinDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        CGDisplayIsBuiltin(displayID) != 0
    }

    func isClamshellClosed() -> Bool {
        let port = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleClamshell"))
        guard port != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(port) }

        guard let value = IORegistryEntryCreateCFProperty(
            port, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? Bool else {
            return false
        }
        return value
    }

    func setBuiltinDisplayEnabled(_ enabled: Bool, sessionScoped: Bool = false) -> Bool {
        guard resolveSymbolsIfNeeded(),
              let configureDisplayEnabled
        else {
            return false
        }

        guard let builtinID = builtinDisplayID() else {
            Self.logger.error("setBuiltinDisplayEnabled(\(enabled)): no built-in display ID")
            return false
        }

        var config: CGDisplayConfigRef?
        var error = CGBeginDisplayConfiguration(&config)
        guard error == .success, let config else {
            Self.logger.error("CGBeginDisplayConfiguration failed: \(error.rawValue)")
            return false
        }

        error = configureDisplayEnabled(config, builtinID, enabled)
        guard error == .success else {
            Self.logger.error("CGSConfigureDisplayEnabled(\(enabled)) on \(builtinID) failed: \(error.rawValue)")
            return false
        }

        // In the zero-displays state a "permanent" enable can be silently
        // ignored — the safety ladder escalates to a session-scoped one.
        let option: CGConfigureOption = sessionScoped ? .forSession : .permanently
        error = CGCompleteDisplayConfiguration(config, option)
        guard error == .success else {
            Self.logger.error("CGCompleteDisplayConfiguration failed: \(error.rawValue)")
            return false
        }

        Self.logger.info("built-in display \(enabled ? "enabled" : "disabled", privacy: .public)\(sessionScoped ? " (session)" : "", privacy: .public)")
        return true
    }

    // MARK: - Private

    private func remember(_ id: CGDirectDisplayID) {
        lastKnownBuiltinID = id
        UserDefaults.standard.set(Int(id), forKey: AppStorageKeys.builtinDisplayKnownID)
    }

    private func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var displays = Array(repeating: CGDirectDisplayID(), count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return [] }
        return displays
    }

    private func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var displays = Array(repeating: CGDirectDisplayID(), count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return displays
    }

    /// The private CGS display list — includes displays disabled via SkyLight
    /// (and a few never-attached virtual slots; callers filter by builtin).
    private func cgsDisplayIDs() -> [CGDirectDisplayID] {
        guard resolveSymbolsIfNeeded(), let getDisplayList else { return [] }

        var count: UInt32 = 0
        guard getDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = Array(repeating: CGDirectDisplayID(), count: Int(count))
        guard getDisplayList(count, &displays, &count) == .success else { return [] }
        return displays
    }

    private func resolveSymbolsIfNeeded() -> Bool {
        if configureDisplayEnabled != nil, getDisplayList != nil {
            return true
        }

        guard handle == nil else { return false }
        handle = dlopen(frameworkPath, RTLD_NOW)
        guard let handle else { return false }

        // Historical name first (used by DisableMonitor & friends), newer
        // SkyLight alias as fallback — both resolve on macOS 26.
        configureDisplayEnabled =
            load(handle: handle, symbol: "CGSConfigureDisplayEnabled")
                ?? load(handle: handle, symbol: "SLSConfigureDisplayEnabled")
        getDisplayList = load(handle: handle, symbol: "CGSGetDisplayList")

        if configureDisplayEnabled == nil {
            Self.logger.error("SkyLight display-configure symbol not found")
        }
        return configureDisplayEnabled != nil
    }

    private func load<T>(handle: UnsafeMutableRawPointer, symbol: String) -> T? {
        guard let pointer = dlsym(handle, symbol) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    deinit {
        if let handle {
            dlclose(handle)
        }
    }
}
