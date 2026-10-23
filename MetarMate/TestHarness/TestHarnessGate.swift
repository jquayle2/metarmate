// Compiled only into Debug and TestFlight builds; the App Store build has none of it (audit #21).
#if DEBUG || TESTFLIGHT

import Foundation

// MARK: - Test Harness Gate
//
// Two layers keep the METAR Injection harness out of the App Store:
//
// 1. Compile time (the real boundary). Every harness file, this one included, is wrapped in
//    `#if DEBUG || TESTFLIGHT`. TESTFLIGHT is set only on the TestFlight build configuration, which
//    the "MetarMate TestFlight" scheme archives with. The App Store archive (scheme "MetarMate",
//    Release) has no harness code and no entry chip. App Review installs carry a sandbox receipt,
//    so a runtime check alone could not keep reviewers out (audit #21, 2.2 risk).
//    MetarMateUITests/HarnessAbsentUITests.swift proves the chip is absent in a Release build.
//
// 2. Runtime (belt and braces inside Debug/TestFlight builds). The receipt filename:
//   • "sandboxReceipt"  → Debug (device + simulator) and TestFlight        → harness ALLOWED
//   • "receipt"         → App Store production download                     → harness DENIED
//   • nil (absent)      → no receipt URL at all                             → harness DENIED (fail-closed)
// The filename is set by the INSTALL CHANNEL, not the build configuration, so a local build
// always reports "sandboxReceipt". The predicate is a pure function of the filename and is
// unit-tested in MetarMateTests/TestHarnessGateTests.swift.
enum TestHarnessGate {

    /// Pure, testable predicate. The ONLY place the runtime allow/deny rule lives.
    /// nil → false is the fail-closed guarantee: if the receipt is ever absent, the harness is denied.
    static func isTestFlightOrDebug(receiptName: String?) -> Bool {
        receiptName == "sandboxReceipt"
    }

    /// The live receipt filename, or nil when there is no receipt URL (can happen in the simulator).
    static var receiptName: String? {
        Bundle.main.appStoreReceiptURL?.lastPathComponent
    }

    /// Launch argument UI tests pass to open the runtime layer in the simulator, whose receipt
    /// filename isn't "sandboxReceipt". Only UI tests can pass launch arguments, and this code
    /// doesn't exist in the App Store build, so the HarnessAbsentUITests assertion there means
    /// "compiled out", not "gate closed".
    static let uiTestForceArgument = "-UITestForceHarnessGate"

    /// True only when the harness entry is permitted. Gates BOTH the entry gesture and the screen.
    static var isAvailable: Bool {
        ProcessInfo.processInfo.arguments.contains(uiTestForceArgument)
            || isTestFlightOrDebug(receiptName: receiptName)
    }
}

#endif
