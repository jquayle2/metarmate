import Testing
import SwiftData
import Foundation
@testable import MetarMate

// A3 step 3: custom minimums profiles are Pro; the built-in starters are free and read-only.
// ProfileAccess.usableProfile is the lapsed-Pro rule VerdictProfile.current() calls at merge.
@MainActor
@Suite(.serialized)
struct ProfileAccessTests {

    private func makeContext() throws -> ModelContext {
        let schema = Schema(versionedSchema: MetarMateSchemaV1.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: [config]))
    }

    private func seededStarters(_ ctx: ModelContext) throws -> [MinimumsProfile] {
        let starters = MinimumsProfile.builtInStarters()
        starters.forEach(ctx.insert)
        try ctx.save()
        return starters
    }

    @Test func starterIsAlwaysUsable() throws {
        let ctx = try makeContext()
        let starters = try seededStarters(ctx)
        let student = try #require(starters.first { $0.builtInKey == "student" })
        for gating in [true, false] {
            for isPro in [true, false] {
                #expect(ProfileAccess.usableProfile(active: student, isPro: isPro, starters: starters, gatingEnabled: gating) === student)
            }
        }
    }

    @Test func customProfileNeedsProWhenGated() throws {
        let ctx = try makeContext()
        let starters = try seededStarters(ctx)
        let mine = MinimumsProfile(name: "Mine", isBuiltIn: false, maxCrosswindKt: 12)
        ctx.insert(mine)
        let vfrDay = try #require(starters.first { $0.builtInKey == "vfrDay" })

        #expect(ProfileAccess.usableProfile(active: mine, isPro: true, starters: starters, gatingEnabled: true) === mine)
        // Lapsed: the verdict uses VFR day; the custom profile isn't touched.
        #expect(ProfileAccess.usableProfile(active: mine, isPro: false, starters: starters, gatingEnabled: true) === vfrDay)
        #expect(mine.maxCrosswindKt == 12)
        // TestFlight (gating off): everyone keeps their custom profile.
        #expect(ProfileAccess.usableProfile(active: mine, isPro: false, starters: starters, gatingEnabled: false) === mine)
    }

    @Test func fallbackWithoutVFRDayUsesAnotherStarter() throws {
        let ctx = try makeContext()
        let starters = try seededStarters(ctx).filter { $0.builtInKey != "vfrDay" }
        let mine = MinimumsProfile(name: "Mine", isBuiltIn: false)
        let usable = ProfileAccess.usableProfile(active: mine, isPro: false, starters: starters + [mine], gatingEnabled: true)
        #expect(usable?.isBuiltIn == true)
        #expect(ProfileAccess.usableProfile(active: nil, isPro: true, starters: [], gatingEnabled: true) == nil)
    }

    @Test func lapsedNoticeNamesTheStarter() {
        #expect(ProfileAccess.lapsedNotice(starterName: "VFR day") ==
                "Your custom profiles are saved. Verdicts use the VFR day starter until Pro is restored.")
    }

    // MARK: Edited-starter migration

    @Test func editedActiveStarterBecomesActiveCustomProfileAndStarterResets() throws {
        let savedToken = UserDefaults.standard.string(forKey: ActiveMinimumsProfile.key)
        defer { UserDefaults.standard.set(savedToken, forKey: ActiveMinimumsProfile.key) }

        let ctx = try makeContext()
        let starters = try seededStarters(ctx)
        let vfrDay = try #require(starters.first { $0.builtInKey == "vfrDay" })
        let canonical = try #require(MinimumsProfile.builtInStarters().first { $0.builtInKey == "vfrDay" })
        vfrDay.maxCrosswindKt = (canonical.maxCrosswindKt ?? 10) + 7
        vfrDay.minCeilingFt = 4_200
        try ctx.save()
        ActiveMinimumsProfile.set(vfrDay)

        let created = StarterProfileMigration.migrateEditedStarters(in: ctx)

        #expect(created == ["VFR day (edited)"])
        let copy = try #require(try ctx.fetch(FetchDescriptor<MinimumsProfile>()).first { $0.name == "VFR day (edited)" })
        #expect(!copy.isBuiltIn)
        #expect(copy.maxCrosswindKt == (canonical.maxCrosswindKt ?? 10) + 7)
        #expect(copy.minCeilingFt == 4_200)
        #expect(StarterProfileMigration.sameValues(vfrDay, canonical))           // starter reset
        #expect(ActiveMinimumsProfile.storedToken() == copy.activeToken)         // tester keeps their values

        // Idempotent: a second launch changes nothing.
        #expect(StarterProfileMigration.migrateEditedStarters(in: ctx).isEmpty)
        #expect(try ctx.fetchCount(FetchDescriptor<MinimumsProfile>()) == starters.count + 1)
    }

    @Test func uneditedStartersAreLeftAloneAndInactiveEditKeepsActive() throws {
        let savedToken = UserDefaults.standard.string(forKey: ActiveMinimumsProfile.key)
        defer { UserDefaults.standard.set(savedToken, forKey: ActiveMinimumsProfile.key) }

        let ctx = try makeContext()
        let starters = try seededStarters(ctx)
        #expect(StarterProfileMigration.migrateEditedStarters(in: ctx).isEmpty)

        let student = try #require(starters.first { $0.builtInKey == "student" })
        let ifr = try #require(starters.first { $0.builtInKey == "ifrCurrent" })
        ActiveMinimumsProfile.set(ifr)
        student.maxGustKt = 99
        try ctx.save()

        #expect(StarterProfileMigration.migrateEditedStarters(in: ctx) == ["Student (edited)"])
        #expect(ActiveMinimumsProfile.storedToken() == ifr.activeToken)
    }
}
