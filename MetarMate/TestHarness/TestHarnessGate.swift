import Foundation

// MARK: - Test Harness Gate
//
// The runtime boundary that keeps the METAR Injection harness OUT of the App Store while leaving
// it reachable in Debug builds and TestFlight. Deliberately NOT wrapped in `#if DEBUG`: that would
// compile the harness out of the TestFlight Release build, and TestFlight is exactly where the
// pilots who exercise the adverse-weather cases live.
//
// The boundary is the App Store receipt filename:
//   • "sandboxReceipt"  → Debug (device + simulator) and TestFlight        → harness ALLOWED
//   • "receipt"         → App Store production download                     → harness DENIED
//   • nil (absent)      → no receipt URL at all                             → harness DENIED (fail-closed)
//
// IMPORTANT — what this can and cannot prove locally:
// The receipt filename is set by the INSTALL CHANNEL, not the build configuration. A locally-built
// Release/Archive still reports "sandboxReceipt" — identical to Debug — because only an actual App
// Store download stamps a production "receipt". So you cannot make `isAvailable` return false by
// building Release locally. What IS provable locally: the predicate below is a pure function of the
// filename (unit-tested: "receipt"→false, "sandboxReceipt"→true, nil→false), and it compiles into
// the Release build (no #if DEBUG), so the logic ships and can be reasoned about. See
// MetarMateTests/TestHarnessGateTests.swift and docs/PRE_MERGE_TEST_PLAN.md.
enum TestHarnessGate {

    /// Pure, testable predicate. The ONLY place the allow/deny rule lives.
    /// nil → false is the fail-closed guarantee: if the receipt is ever absent, the harness is denied.
    static func isTestFlightOrDebug(receiptName: String?) -> Bool {
        receiptName == "sandboxReceipt"
    }

    /// The live receipt filename, or nil when there is no receipt URL (can happen in the simulator).
    static var receiptName: String? {
        Bundle.main.appStoreReceiptURL?.lastPathComponent
    }

    /// True only when the harness entry is permitted. Gates BOTH the entry gesture and the screen.
    static var isAvailable: Bool {
        isTestFlightOrDebug(receiptName: receiptName)
    }
}
