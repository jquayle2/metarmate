import Testing
import SwiftData
import Foundation
@testable import MetarMate

// Integration seam: VerdictProfile.current() (verdict branch) applies A3's lapsed-Pro rule
// (ProfileAccess.usableProfile), so every verdict surface judges a lapsed user's custom
// profile against a starter while the custom profile stays selected.
@MainActor
@Suite(.serialized)
struct VerdictProfileSeamTests {

    private func makeContext() throws -> ModelContext {
        let schema = Schema(versionedSchema: MetarMateSchemaV1.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: [config]))
    }

    /// Starters + one custom profile, with the custom one active. Restores the stored pointer after.
    private func withCustomActive(_ body: (ModelContext, MinimumsProfile) throws -> Void) throws {
        let saved = UserDefaults.standard.string(forKey: ActiveMinimumsProfile.key)
        defer { UserDefaults.standard.set(saved, forKey: ActiveMinimumsProfile.key) }
        let ctx = try makeContext()
        MinimumsProfile.builtInStarters().forEach(ctx.insert)
        let mine = MinimumsProfile(name: "Mine", isBuiltIn: false, maxCrosswindKt: 12)
        ctx.insert(mine)
        try ctx.save()
        ActiveMinimumsProfile.set(mine)
        try body(ctx, mine)
    }

    @Test func lapsedCustomProfileFallsBackToVFRDayStarter() throws {
        try withCustomActive { ctx, mine in
            let used = try #require(VerdictProfile.current(in: ctx, isPro: false, gatingEnabled: true))
            #expect(used.isBuiltIn && used.builtInKey == "vfrDay")
            #expect(VerdictProfile.fallbackStarter(in: ctx, isPro: false, gatingEnabled: true) === used)
            // The custom profile stays the selected one, so it returns with Pro.
            #expect(ActiveMinimumsProfile.storedToken() == mine.activeToken)
        }
    }

    @Test func proAndUngatedKeepTheCustomProfile() throws {
        try withCustomActive { ctx, mine in
            #expect(VerdictProfile.current(in: ctx, isPro: true, gatingEnabled: true) === mine)
            #expect(VerdictProfile.current(in: ctx, isPro: false, gatingEnabled: false) === mine)
            #expect(VerdictProfile.fallbackStarter(in: ctx, isPro: true, gatingEnabled: true) == nil)
        }
    }

    @Test func activeStarterNeverFallsBack() throws {
        try withCustomActive { ctx, _ in
            let student = try #require(try ctx.fetch(FetchDescriptor<MinimumsProfile>()).first { $0.builtInKey == "student" })
            ActiveMinimumsProfile.set(student)
            #expect(VerdictProfile.current(in: ctx, isPro: false, gatingEnabled: true) === student)
            #expect(VerdictProfile.fallbackStarter(in: ctx, isPro: false, gatingEnabled: true) == nil)
        }
    }

    // The status verdicts use before StoreKit answers (Jeff, Oct 24): real once loaded, else the
    // last saved status, else Pro.
    @Test func verdictProStatusBeforeAndAfterLoad() {
        #expect(StoreManager.proStatus(loaded: true, isPro: false, savedStatus: true) == false)
        #expect(StoreManager.proStatus(loaded: true, isPro: true, savedStatus: false) == true)
        #expect(StoreManager.proStatus(loaded: false, isPro: false, savedStatus: false) == false)
        #expect(StoreManager.proStatus(loaded: false, isPro: false, savedStatus: true) == true)
        #expect(StoreManager.proStatus(loaded: false, isPro: false, savedStatus: nil) == true)
    }

    // Detail card profile menu: starters for everyone; a custom profile goes through the Pro gate.
    @Test func cardMenuGatesCustomProfilesOnly() throws {
        let ctx = try makeContext()
        let starter = try #require(MinimumsProfile.builtInStarters().first)
        let mine = MinimumsProfile(name: "Mine", isBuiltIn: false)
        ctx.insert(starter); ctx.insert(mine)
        for isPro in [true, false] {
            for gating in [true, false] {
                #expect(VerdictCard.menuAction(for: starter, isPro: isPro, gatingEnabled: gating) == .select)
            }
        }
        #expect(VerdictCard.menuAction(for: mine, isPro: true, gatingEnabled: true) == .select)
        #expect(VerdictCard.menuAction(for: mine, isPro: false, gatingEnabled: true) == .paywall)
        #expect(VerdictCard.menuAction(for: mine, isPro: false, gatingEnabled: false) == .select)
    }

    // The card's notice names the starter the verdict actually used.
    @Test func cardNoticeNamesTheFallbackStarter() throws {
        try withCustomActive { ctx, _ in
            let starter = try #require(VerdictProfile.fallbackStarter(in: ctx, isPro: false, gatingEnabled: true))
            #expect(ProfileAccess.lapsedNotice(starterName: starter.name)
                    == "Your custom profiles are saved. Verdicts use the \(starter.name) starter until Pro is restored.")
            #expect(VerdictProfile.current(in: ctx, isPro: false, gatingEnabled: true) === starter)
        }
    }
}
