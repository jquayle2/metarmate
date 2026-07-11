import Testing
@testable import MetarMate

// Proves the receipt gate is a PURE function of the receipt filename — the only thing provable
// locally, since the runtime filename is set by install channel, not build config (see
// TestHarnessGate + docs/PRE_MERGE_TEST_PLAN.md). The nil→false case is the fail-closed guarantee:
// if the receipt is ever absent, the harness is DENIED.
struct TestHarnessGateTests {

    @Test func sandboxReceiptIsAllowed() {
        #expect(TestHarnessGate.isTestFlightOrDebug(receiptName: "sandboxReceipt") == true)
    }

    @Test func productionReceiptIsDenied() {
        // App Store production download → "receipt" → harness unreachable.
        #expect(TestHarnessGate.isTestFlightOrDebug(receiptName: "receipt") == false)
    }

    @Test func nilReceiptFailsClosed() {
        // No receipt URL at all (can happen in the simulator) → DENIED.
        #expect(TestHarnessGate.isTestFlightOrDebug(receiptName: nil) == false)
    }

    @Test func unexpectedNameFailsClosed() {
        #expect(TestHarnessGate.isTestFlightOrDebug(receiptName: "somethingElse") == false)
    }
}
