import Foundation

// MARK: - BuildChannel
// Which archive this binary came from, at compile time. TESTFLIGHT is set only on the TestFlight
// build configuration (scheme "MetarMate TestFlight"); App Store archives use Release without it.
nonisolated enum BuildChannel {
    #if TESTFLIGHT
    static let isTestFlight = true
    #else
    static let isTestFlight = false
    #endif

    /// "Version 1.2 (22)", plus " · TestFlight" in TestFlight builds, so a tester build is never
    /// mistaken for the one to submit (Jeff, Oct 23). Shown at the bottom of Customize Layout.
    static var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return "Version \(version) (\(build))" + (isTestFlight ? " · TestFlight" : "")
    }
}
