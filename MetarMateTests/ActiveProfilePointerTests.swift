import Testing
import SwiftData
import Foundation
@testable import MetarMate

// Regression coverage for the Item-0 active-profile flip: the active-profile pointer was keyed on
// the volatile `uuid`, so the launch-time uuid repair (ensureUniqueUUIDs) and store migration
// silently re-anchored the user's choice away (IFR current -> VFR day/Student). The pointer now
// anchors built-ins on the stable builtInKey ("builtin:<key>"), immune to uuid churn.
@MainActor
struct ActiveProfilePointerTests {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([MinimumsProfile.self, AirportWatch.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: [config]))
    }

    // Three keyed built-ins with the given uuids, in canonical seed order.
    private func seedKeyed(_ ctx: ModelContext, uuids: [UUID]) throws -> [String: MinimumsProfile] {
        let specs = [("Student", "student"), ("VFR day", "vfrDay"), ("IFR current", "ifrCurrent")]
        var byKey: [String: MinimumsProfile] = [:]
        for (i, (name, key)) in specs.enumerated() {
            let p = MinimumsProfile(name: name, isBuiltIn: true, builtInKey: key, uuid: uuids[i])
            ctx.insert(p)
            byKey[key] = p
        }
        try ctx.save()
        return byKey
    }

    private func clearPointer() {
        UserDefaults.standard.removeObject(forKey: ActiveMinimumsProfile.key)
    }

    // Core fix: once the selection is stored in stable form, a uuid collision + dedup repair must
    // NOT change which profile is active.
    @Test func stableTokenSurvivesUUIDChurn() throws {
        clearPointer()
        let ctx = try makeContext()
        let p = try seedKeyed(ctx, uuids: [UUID(), UUID(), UUID()])
        ActiveMinimumsProfile.set(p["ifrCurrent"]!)                       // user picks IFR current
        #expect(ActiveMinimumsProfile.storedToken() == "builtin:ifrCurrent")

        // Force a collision so the repair actually reassigns uuids, then run it.
        p["student"]!.uuid = p["vfrDay"]!.uuid
        try ctx.save()
        MinimumsProfile.ensureUniqueUUIDs(in: ctx)

        #expect(ActiveMinimumsProfile.resolve(in: ctx)?.name == "IFR current")
        #expect(ActiveMinimumsProfile.storedToken() == "builtin:ifrCurrent")
    }

    // Existing installs: the pointer is a raw uuid that still matches exactly one profile. It must
    // resolve to that profile and self-heal to the stable token form across the launch repair.
    @Test func legacyUUIDPointerPreservedAndHealed() throws {
        clearPointer()
        let ctx = try makeContext()
        // Pre-batch latent state: keys not yet backfilled, but uuids are unique.
        let ifr = UUID()
        let specs = [("Student", UUID()), ("VFR day", UUID()), ("IFR current", ifr)]
        for (name, id) in specs {
            ctx.insert(MinimumsProfile(name: name, isBuiltIn: true, builtInKey: nil, uuid: id))
        }
        try ctx.save()
        UserDefaults.standard.set(ifr.uuidString, forKey: ActiveMinimumsProfile.key)   // legacy pointer

        // Launch repair order.
        MinimumsProfile.backfillBuiltInKeys(in: ctx)
        MinimumsProfile.ensureUniqueUUIDs(in: ctx)

        #expect(ActiveMinimumsProfile.resolve(in: ctx)?.name == "IFR current")
        #expect(ActiveMinimumsProfile.storedToken() == "builtin:ifrCurrent")          // healed
    }

    // Unrecoverable legacy case (the original shared-uuid footgun): a raw-uuid pointer that matches
    // ALL built-ins can't be disambiguated, so the user's intent is genuinely lost. The fix must at
    // least degrade gracefully — land on a valid built-in, leave uuids unique, never crash.
    @Test func sharedUUIDLegacyDegradesGracefully() throws {
        clearPointer()
        let ctx = try makeContext()
        let shared = UUID()
        _ = try seedKeyedSharingUUID(ctx, shared: shared)
        UserDefaults.standard.set(shared.uuidString, forKey: ActiveMinimumsProfile.key)

        MinimumsProfile.backfillBuiltInKeys(in: ctx)
        MinimumsProfile.ensureUniqueUUIDs(in: ctx)

        let resolved = ActiveMinimumsProfile.resolve(in: ctx)
        #expect(resolved != nil && resolved!.isBuiltIn)
        let all = try ctx.fetch(FetchDescriptor<MinimumsProfile>())
        #expect(Set(all.map(\.uuid)).count == all.count)   // uuids now unique
    }

    private func seedKeyedSharingUUID(_ ctx: ModelContext, shared: UUID) throws -> [MinimumsProfile] {
        // builtInKey nil to mirror the pre-batch state that produced the shared uuid.
        let names = ["Student", "VFR day", "IFR current"]
        let ps = names.map { MinimumsProfile(name: $0, isBuiltIn: true, builtInKey: nil, uuid: shared) }
        ps.forEach { ctx.insert($0) }
        try ctx.save()
        return ps
    }
}
