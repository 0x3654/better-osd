//
//  HIDUtilRemapper.swift
//  BetterOSD
//

import Foundation

// Applies / removes a hidutil UserKeyMapping that redirects the physical
// keyboard-brightness keys (F5/F6) to Dictation and Do Not Disturb at the
// keyDown level, while leaving the NX systemDefined illumination events (21/22)
// intact so BetterOSD can intercept them for the brightness OSD.
//
// The mapping is volatile — it resets on reboot.  BetterOSD re-applies it at
// every launch when the keyboard-backlight OSD is enabled with the standard
// F5/F6 assignment, so no separate LaunchAgent is needed.
//
// Existing third-party UserKeyMapping entries are preserved: we only add or
// remove the two F5/F6 rows this app owns.
enum HIDUtilRemapper {

    // MARK: - HID usage codes

    // Src: Consumer page (0x0C) usage 0xCF  — Keyboard Brightness Down (F5)
    // Dst: Vendor page  (0xFF) usage 0x09   — Dictation
    // Src: Generic Desktop (0x01) usage 0x9B — Keyboard Brightness Up (F6)
    // Dst: Vendor page  (0xFF) usage 0x08   — Do Not Disturb
    static let f5Source: UInt64 = 0xC000000CF
    static let f5Destination: UInt64 = 0xFF00000009
    static let f6Source: UInt64 = 0x10000009B
    static let f6Destination: UInt64 = 0xFF00000008

    /// Source usages this app owns. Used to strip / replace only our rows.
    static let ownedSources: Set<UInt64> = [f5Source, f6Source]

    struct Entry: Equatable, Sendable {
        var source: UInt64
        var destination: UInt64
    }

    static let ownedEntries: [Entry] = [
        Entry(source: f5Source, destination: f5Destination),
        Entry(source: f6Source, destination: f6Destination),
    ]

    // MARK: - Pure merge (unit-tested)

    /// Drop any prior rows for our F5/F6 sources, then append our mappings.
    static func mappingsByAddingOurs(to existing: [Entry]) -> [Entry] {
        mappingsByRemovingOurs(from: existing) + ownedEntries
    }

    /// Remove only this app's F5/F6 entries; leave everything else alone.
    static func mappingsByRemovingOurs(from existing: [Entry]) -> [Entry] {
        existing.filter { !ownedSources.contains($0.source) }
    }

    static func propertyPayload(for entries: [Entry]) -> String {
        let rows = entries.map {
            "{\"HIDKeyboardModifierMappingSrc\":\(hex($0.source)),\"HIDKeyboardModifierMappingDst\":\(hex($0.destination))}"
        }.joined(separator: ",")
        return "{\"UserKeyMapping\":[\(rows)]}"
    }

    // MARK: - Public API

    /// Redirects F5 → Dictation and F6 → DND at the keyDown level, preserving
    /// any unrelated UserKeyMapping entries already present.
    /// Dispatched to a background queue — does not block the main thread.
    static func applyF5F6Remapping() {
        mutateMappings { mappingsByAddingOurs(to: $0) }
    }

    /// Removes only this app's F5/F6 remapping rows, restoring those keys
    /// without wiping third-party mappings.
    /// Dispatched to a background queue — does not block the main thread.
    static func clearRemapping() {
        mutateMappings { mappingsByRemovingOurs(from: $0) }
    }

    // MARK: - I/O

    /// Injectable for tests. Returns the current UserKeyMapping entries, or
    /// an empty array when unset / unreadable.
    static var readMappings: () -> [Entry] = {
        parseMappings(from: runHIDUtil(args: ["property", "--get", "UserKeyMapping"]))
    }

    /// Injectable for tests. Writes the full UserKeyMapping property.
    static var writeMappings: ([Entry]) -> Void = { entries in
        _ = runHIDUtil(args: ["property", "--set", propertyPayload(for: entries)])
    }

    private static func mutateMappings(_ transform: @escaping ([Entry]) -> [Entry]) {
        DispatchQueue.global(qos: .userInitiated).async {
            let next = transform(readMappings())
            writeMappings(next)
        }
    }

    /// Parses `hidutil property --get UserKeyMapping` table output. Values are
    /// OpenStep-style arrays of Src/Dst pairs (decimal). We take the first
    /// non-empty Value block — after a global `--set` every keyboard reports
    /// the same mapping.
    static func parseMappings(from output: String) -> [Entry] {
        // Prefer an explicit array block; fall back to scanning the whole dump.
        let block: String
        if let range = output.range(of: #"UserKeyMapping\s+\("#, options: .regularExpression) {
            let opening = output.index(before: range.upperBound)
            if let end = matchingClosingParen(in: output, openingAt: opening) {
                block = String(output[output.index(after: opening)..<end])
            } else {
                block = output
            }
        } else {
            block = output
        }

        let pattern = #"HIDKeyboardModifierMappingSrc\s*=\s*(\d+)\s*;\s*HIDKeyboardModifierMappingDst\s*=\s*(\d+)\s*;"#
        let altPattern = #"HIDKeyboardModifierMappingDst\s*=\s*(\d+)\s*;\s*HIDKeyboardModifierMappingSrc\s*=\s*(\d+)\s*;"#

        var entries: [Entry] = []
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let ns = block as NSString
            for match in regex.matches(in: block, range: NSRange(location: 0, length: ns.length)) {
                let src = UInt64(ns.substring(with: match.range(at: 1))) ?? 0
                let dst = UInt64(ns.substring(with: match.range(at: 2))) ?? 0
                entries.append(Entry(source: src, destination: dst))
            }
        }
        if entries.isEmpty, let regex = try? NSRegularExpression(pattern: altPattern) {
            let ns = block as NSString
            for match in regex.matches(in: block, range: NSRange(location: 0, length: ns.length)) {
                let dst = UInt64(ns.substring(with: match.range(at: 1))) ?? 0
                let src = UInt64(ns.substring(with: match.range(at: 2))) ?? 0
                entries.append(Entry(source: src, destination: dst))
            }
        }
        return entries
    }

    private static func matchingClosingParen(in text: String, openingAt openIndex: String.Index) -> String.Index? {
        var depth = 0
        var index = openIndex
        while index < text.endIndex {
            let ch = text[index]
            if ch == "(" { depth += 1 }
            if ch == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func hex(_ value: UInt64) -> String {
        String(format: "0x%llX", value)
    }

    @discardableResult
    private static func runHIDUtil(args: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        task.arguments = args
        let stdout = Pipe()
        task.standardOutput = stdout
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return ""
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
