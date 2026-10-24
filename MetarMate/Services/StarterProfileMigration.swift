import Foundation
import os
import SwiftData

// MARK: - StarterProfileMigration (A3 step 3)
// Built-in starters are read-only from A3 on (Jeff, Oct 23): a verdict "vs VFR day starter" must
// mean the canonical VFR day values. Testers could edit starters before, so at launch each starter
// whose values differ from canonical is copied to a custom profile "<starter> (edited)" with the
// tester's values, that copy becomes active if the starter was, and the starter is reset. Nothing
// is lost. Idempotent: once reset, a starter matches canonical and is skipped. No schema change.
enum StarterProfileMigration {

    /// Returns the names of the custom profiles created.
    @discardableResult
    static func migrateEditedStarters(in context: ModelContext) -> [String] {
        MinimumsProfile.backfillBuiltInKeys(in: context)   // edits are matched on builtInKey
        let starters = (try? context.fetch(
            FetchDescriptor<MinimumsProfile>(predicate: #Predicate { $0.isBuiltIn })
        )) ?? []
        let canonical = Dictionary(
            MinimumsProfile.builtInStarters().compactMap { s in s.builtInKey.map { ($0, s) } },
            uniquingKeysWith: { first, _ in first })

        var created: [String] = []
        for starter in starters {
            guard let key = starter.builtInKey, let reference = canonical[key],
                  !sameValues(starter, reference) else { continue }
            let copy = MinimumsProfile(
                name: "\(starter.name) (edited)",
                isBuiltIn: false,
                maxCrosswindKt: starter.maxCrosswindKt,
                maxGustKt: starter.maxGustKt,
                minVisibilitySM: starter.minVisibilitySM,
                minCeilingFt: starter.minCeilingFt,
                minFlightCategory: starter.minCategory,
                maxSustainedWindKt: starter.maxSustainedWindKt
            )
            context.insert(copy)
            if ActiveMinimumsProfile.storedToken() == starter.activeToken {
                ActiveMinimumsProfile.set(copy)   // the tester keeps verdicts against their own values
            }
            starter.resetToBuiltInDefault()
            created.append(copy.name)
        }
        if !created.isEmpty {
            try? context.save()
            Log.load.info("[profiles] edited starters moved to custom profiles: \(created.joined(separator: ", "), privacy: .public)")
        }
        return created
    }

    static func sameValues(_ a: MinimumsProfile, _ b: MinimumsProfile) -> Bool {
        a.maxCrosswindKt == b.maxCrosswindKt
            && a.maxGustKt == b.maxGustKt
            && a.minVisibilitySM == b.minVisibilitySM
            && a.minCeilingFt == b.minCeilingFt
            && a.minFlightCategory == b.minFlightCategory
            && a.maxSustainedWindKt == b.maxSustainedWindKt
    }
}
