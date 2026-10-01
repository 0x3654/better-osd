//
//  HIDUtilRemapperTests.swift
//  BetterOSDTests
//

@testable import BetterOSD
import Testing

@MainActor
struct HIDUtilRemapperTests {
    private let thirdParty = HIDUtilRemapper.Entry(source: 0x700000039, destination: 0x700000029)

    @Test
    func addingOursPreservesThirdPartyMappings() {
        let merged = HIDUtilRemapper.mappingsByAddingOurs(to: [thirdParty])
        #expect(merged.contains(thirdParty))
        #expect(Set(merged.map(\.source)).isSuperset(of: HIDUtilRemapper.ownedSources))
        #expect(merged.count == 1 + HIDUtilRemapper.ownedEntries.count)
    }

    @Test
    func addingOursReplacesPriorOwnedRowsWithoutDuplicating() {
        let stale = HIDUtilRemapper.Entry(
            source: HIDUtilRemapper.f5Source,
            destination: 0x1
        )
        let merged = HIDUtilRemapper.mappingsByAddingOurs(to: [thirdParty, stale])
        let f5 = merged.filter { $0.source == HIDUtilRemapper.f5Source }
        #expect(f5.count == 1)
        #expect(f5.first?.destination == HIDUtilRemapper.f5Destination)
        #expect(merged.contains(thirdParty))
    }

    @Test
    func clearingRemovesOnlyOwnedEntries() {
        let existing = [thirdParty] + HIDUtilRemapper.ownedEntries
        let cleared = HIDUtilRemapper.mappingsByRemovingOurs(from: existing)
        #expect(cleared == [thirdParty])
    }

    @Test
    func clearingEmptyOwnedListIsNoOpForForeignMappings() {
        #expect(HIDUtilRemapper.mappingsByRemovingOurs(from: [thirdParty]) == [thirdParty])
        #expect(HIDUtilRemapper.mappingsByRemovingOurs(from: []) == [])
    }

    @Test
    func propertyPayloadUsesHexAndWrapsArray() {
        let payload = HIDUtilRemapper.propertyPayload(for: HIDUtilRemapper.ownedEntries)
        #expect(payload.contains("UserKeyMapping"))
        #expect(payload.contains("0xC000000CF"))
        #expect(payload.contains("0x10000009B"))
        #expect(payload.contains("0xFF00000009"))
        #expect(payload.contains("0xFF00000008"))
    }

    @Test
    func parseMappingsReadsHidutilOpenStepDump() {
        // hidutil prints Dst before Src; values are decimal.
        let dump = """
        RegistryID  Key                   Value
        10000093c   UserKeyMapping   (
                {
                HIDKeyboardModifierMappingDst = 30064771113;
                HIDKeyboardModifierMappingSrc = 30064771129;
            },
                {
                HIDKeyboardModifierMappingDst = 1095216660489;
                HIDKeyboardModifierMappingSrc = 51539607759;
            }
        )
        """
        let parsed = HIDUtilRemapper.parseMappings(from: dump)
        #expect(parsed.count == 2)
        #expect(parsed.contains(where: { $0.source == 0x700000039 && $0.destination == 0x700000029 }))
        #expect(parsed.contains(where: { $0.source == 0xC000000CF && $0.destination == 0xFF00000009 }))
    }

    @Test
    func parseMappingsReturnsEmptyForNullDump() {
        let dump = """
        RegistryID  Key                   Value
        10000093c   UserKeyMapping   (null)
        """
        #expect(HIDUtilRemapper.parseMappings(from: dump).isEmpty)
    }
}
