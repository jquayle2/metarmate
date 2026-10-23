import Testing
@testable import MetarMate

// The Pro gating switch follows the build channel (approved Oct 23): off in TestFlight builds so
// beta testers keep everything, on in App Store (Release) and Debug builds. The widget compiles
// the same FeatureFlags.swift; its value is recorded as gating=<on|off> in the widget diag line.
struct FeatureFlagsTests {
    @Test func proGatingFollowsBuildChannel() {
        #if TESTFLIGHT
        #expect(FeatureFlags.proGatingEnabled == false)
        #expect(BuildChannel.isTestFlight)
        #else
        #expect(FeatureFlags.proGatingEnabled == true)
        #expect(!BuildChannel.isTestFlight)
        #endif
    }
}
