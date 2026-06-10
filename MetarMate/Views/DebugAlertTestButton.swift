import SwiftUI
import SwiftData

// TEMPORARY — remove when Step 5 watch UI lands.
//
// Disposable end-to-end harness for the alert pipeline, for use before real watch-management
// UI exists. One tap evaluates KVGT's CURRENT real weather against a deliberately impossible
// MinimumsProfile (min visibility 99 SM, max crosswind 0 kt) from a nil starting side — so the
// verdict is an unambiguous NO-GO with no synthetic side-flip required. This proves the real
// chain on real weather: fetch -> evaluate -> (nil-side first-eval) shouldFire -> post ->
// foreground presentation. It uses the same GoNoGoEvaluator and NotificationManager.post the
// background pipeline uses, so a fire here means the background's first-check (also nil-side)
// will fire too.
//
// Self-contained: delete this file and the one marked ToolbarItem in NearestAirportsView to
// remove the harness completely.
struct DebugAlertTestButton: View {
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
        await NotificationManager.shared.requestAuthorizationIfNeeded()

        guard let metar = try? await WeatherService.shared.fetchMetar(for: "KVGT") else {
            outcomeText = "KVGT METAR fetch failed."
            showResult = true
            return
        }
        let conditions = AlertConditions(from: metar)

        // Impossible on purpose: forces NO-GO regardless of the day's weather.
        let impossible = MinimumsProfile(name: "TEST impossible",
                                         maxCrosswindKt: 0,
                                         minVisibilitySM: 99)
        let verdict = GoNoGoEvaluator.evaluate(impossible, conditions, previousSide: nil, icao: "KVGT")

        var posted = false
        if verdict.shouldFire {
            posted = await NotificationManager.shared.post(
                title: "NO-GO — KVGT (test)",
                body: verdict.failingFactors.joined(separator: "; ") + ". " + verdict.sourceLabel + "."
            )
        }

        outcomeText = """
        Verdict: \(verdict.newSide == .noGo ? "NO-GO" : "GO")
        shouldFire (nil prevSide): \(verdict.shouldFire)
        posted (confirmed add): \(posted)
        Check Notification Center for the KVGT alert.
        """
        showResult = true
    }
}
