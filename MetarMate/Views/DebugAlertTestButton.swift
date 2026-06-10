import SwiftUI
import SwiftData

// TEMPORARY — remove when Step 5 watch UI lands.
//
// Disposable end-to-end harness for the alert pipeline, for use before real watch-management
// UI exists. One tap:
//   1. ensures a single hardcoded KVGT watch (evaluated against the active MinimumsProfile),
//   2. runs the shared checkNow once to establish KVGT's current side (and trigger the
//      first-time notification-permission prompt),
//   3. flips the stored side and runs checkNow again, forcing a GO<->NO_GO transition so a real
//      notification reliably fires regardless of KVGT's actual weather that day.
//
// Proves the whole chain: permission prompt -> fetch -> evaluate -> notify -> persist. The
// second run uses the exact same pipeline the background task (Part C) will call.
//
// Self-contained on purpose: delete this file and the one marked ToolbarItem in
// NearestAirportsView to remove the harness completely.
struct DebugAlertTestButton: View {
    @Environment(\.modelContext) private var context
    @State private var outcomeText = ""
    @State private var showResult = false

    var body: some View {
        Button {
            Task { await runTest() }
        } label: {
            Image(systemName: "ladybug.fill")
                .foregroundColor(.pink)
        }
        .alert("Alert pipeline test", isPresented: $showResult) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(outcomeText)
        }
    }

    @MainActor
    private func runTest() async {
        let icao = "KVGT"
        let existing = (try? context.fetch(
            FetchDescriptor<AirportWatch>(predicate: #Predicate { $0.icao == icao })
        )) ?? []
        let watch: AirportWatch
        if let found = existing.first {
            watch = found
        } else {
            watch = AirportWatch(icao: icao)
            context.insert(watch)
            try? context.save()
        }

        await AlertPipeline.checkNow(in: context)        // establish current side + permission prompt
        if let side = watch.side {                       // flip to force a transition on the next run
            watch.side = (side == .go) ? .noGo : .go
            try? context.save()
        }
        let outcome = await AlertPipeline.checkNow(in: context)   // guaranteed transition -> notification

        outcomeText = """
        Watches checked: \(outcome.watchesChecked)
        Notifications fired: \(outcome.notificationsFired)
        Check Notification Center for the KVGT alert.
        """
        showResult = true
    }
}
