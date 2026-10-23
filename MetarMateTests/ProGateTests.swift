import Testing
@testable import MetarMate

// A3 step 3: every Pro gate in both switch states. With gating off (TestFlight) every feature is
// open to everyone; with gating on (App Store, Debug) only Pro opens them. Free features have no
// gate at all: they are not ProFeature cases (D#19–20).
struct ProGateTests {

    @Test func proFeaturesAreExactlyTheD20List() {
        #expect(Set(ProFeature.allCases.map(\.rawValue)) ==
                ["widgets", "customProfiles", "alerts", "siri", "layout"])
    }

    @Test(arguments: ProFeature.allCases)
    func gatingOffOpensEveryFeatureForEveryone(_ feature: ProFeature) {
        #expect(ProGate.allows(feature, isPro: false, gatingEnabled: false))
        #expect(ProGate.allows(feature, isPro: true, gatingEnabled: false))
    }

    @Test(arguments: ProFeature.allCases)
    func gatingOnOpensEveryFeatureOnlyForPro(_ feature: ProFeature) {
        #expect(!ProGate.allows(feature, isPro: false, gatingEnabled: true))
        #expect(ProGate.allows(feature, isPro: true, gatingEnabled: true))
    }

    @Test func defaultSwitchIsThisBuildsSwitch() {
        #expect(ProGate.allows(.widgets, isPro: false) == !FeatureFlags.proGatingEnabled)
    }

    // Widget: gating off → open; saved Pro or StoreKit Pro → open; otherwise locked.
    @Test func widgetAccess() {
        #expect(WidgetProAccess.decide(gatingEnabled: false, savedStatus: false, storeKitSaysPro: false))
        #expect(WidgetProAccess.decide(gatingEnabled: true, savedStatus: true, storeKitSaysPro: false))
        // A family purchase or a fresh install: StoreKit knows before the app has saved anything.
        #expect(WidgetProAccess.decide(gatingEnabled: true, savedStatus: nil, storeKitSaysPro: true))
        #expect(WidgetProAccess.decide(gatingEnabled: true, savedStatus: false, storeKitSaysPro: true))
        #expect(!WidgetProAccess.decide(gatingEnabled: true, savedStatus: false, storeKitSaysPro: false))
        #expect(!WidgetProAccess.decide(gatingEnabled: true, savedStatus: nil, storeKitSaysPro: false))
    }
}
