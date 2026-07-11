import SwiftUI
import os

// MARK: - METAR Injection Harness (TestFlight / Debug only)
//
// Entry: five taps on the "METAR Injection — tap 5×" chip at the bottom of the Favorites content
// (see FavoritesView). BOTH the entry chip and this screen are gated on TestHarnessGate.isAvailable
// (sandbox receipt) so it is unreachable in an App Store production build.
//
// Sections:
//   1. Canned adverse fixtures (A1–A13, T1–T4) — injected, SIMULATED, banner-marked.
//   2. Live spot-check airports — a NORMAL live fetch, clearly labeled LIVE (no banner).
//   3. Free-text paste — arbitrary raw METAR/TAF or NOAA JSON through the same decode→parse seam.
struct MetarInjectionHarnessView: View {
    @Environment(\.dismiss) private var dismiss

    // Prepared navigation payloads (built on tap so a parse failure is caught and shown honestly).
    @State private var simPayload: SimPayload?
    @State private var livePayload: Airport?
    @State private var errorMessage: String?

    // Free-text
    @State private var rawInput: String = ""
    @State private var freeKind: FreeKind = .metar

    enum FreeKind: String, CaseIterable, Identifiable { case metar = "METAR", taf = "TAF"; var id: String { rawValue } }

    var body: some View {
        NavigationStack {
            Group {
                if TestHarnessGate.isAvailable {
                    harnessList
                } else {
                    // Second gate: the screen itself refuses to render outside Debug/TestFlight.
                    unavailableView
                }
            }
            .navigationTitle("METAR Injection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(item: $simPayload) { payload in
                SimulatedWeatherDetailScreen(payload: payload)
            }
            .navigationDestination(item: $livePayload) { airport in
                // Live fetch — no injection, no banner. This is real weather on purpose.
                WeatherDetailView(airport: airport)
            }
            .alert("Parse failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .onAppear {
            Log.load.info("[harness] opened — receiptName=\(TestHarnessGate.receiptName ?? "nil", privacy: .public), available=\(TestHarnessGate.isAvailable, privacy: .public)")
        }
    }

    private var harnessList: some View {
        List {
            Section {
                Text("Every injected screen is fabricated weather, marked with a permanent SIMULATED banner. Read-only: no network, no favorites/SwiftData writes, no widget snapshot.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Button { HarnessAudit.logAll() } label: {
                    Label("Print audit report → Xcode console", systemImage: "doc.text.magnifyingglass")
                }
                Text("Dumps every fixture's parsed values (visibility, wind, ceiling, category, phenomena, DA, trend, TAF hero) to the console. Filter Xcode/Console.app by “harness”. Tapping a fixture also logs just that one.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Section("① Canned adverse fixtures (injected · SIMULATED)") {
                ForEach(MetarInjectionFixtures.all) { fx in
                    Button { present(fixture: fx) } label: { fixtureRow(fx) }
                        .buttonStyle(.plain)
                }
            }

            Section {
                ForEach(MetarInjectionFixtures.liveSpotCheckICAOs, id: \.self) { icao in
                    Button { presentLive(icao: icao) } label: {
                        HStack {
                            Image(systemName: "dot.radiowaves.left.and.right").foregroundColor(.green)
                            Text(icao).font(.body.monospaced())
                            Spacer()
                            Text("LIVE").font(.caption2.bold()).foregroundColor(.green)
                            Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("② Live spot-check airports (real fetch)")
            } footer: {
                Text("A normal live fetch — NOT a guaranteed-adverse injection. Today's weather may be VFR.")
            }

            Section("③ Free-text paste (raw or NOAA JSON)") {
                Picker("Interpret as", selection: $freeKind) {
                    ForEach(FreeKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                TextEditor(text: $rawInput)
                    .font(.system(size: 13).monospaced())
                    .frame(minHeight: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))

                if isRawText {
                    // Persistent caveat whenever the field holds a RAW line (not JSON).
                    Label("Raw text populates present-weather + display only. Visibility, wind, clouds, and category come from NOAA structured fields a raw line doesn’t carry — those render as “—”/unknown, never a default.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(Brand.cautionOrange)
                }

                Button { presentFreeText() } label: {
                    Label("Inject", systemImage: "arrow.right.circle.fill")
                }
                .disabled(rawInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func fixtureRow(_ fx: InjectionFixture) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(fx.id)
                .font(.caption.bold().monospaced())
                .foregroundColor(Brand.accentOrange)
                .frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(fx.title).font(.subheadline.weight(.semibold)).foregroundColor(.primary)
                Text(fx.subtitle).font(.caption).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
    }

    private var unavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill").font(.system(size: 40)).foregroundColor(.secondary)
            Text("Test harness unavailable")
                .font(.headline)
            Text("Only reachable in Debug or TestFlight builds.")
                .font(.subheadline).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions (all build-on-tap; a throw becomes an honest alert, never a fallback model)

    private var isRawText: Bool {
        let t = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && !(t.hasPrefix("{") || t.hasPrefix("["))
    }

    private func present(fixture fx: InjectionFixture) {
        HarnessAudit.log(fx)   // also dump this one case to the console for auditing
        do {
            let injection = try fx.make()
            simPayload = SimPayload(id: fx.id, title: fx.title, airport: fx.airport, injection: injection)
        } catch {
            errorMessage = "\(fx.id): \(error.localizedDescription)"
        }
    }

    private func presentLive(icao: String) {
        if let airport = AirportService.shared.airport(icao: icao) {
            livePayload = airport
        } else {
            errorMessage = "No bundled airport record for \(icao)."
        }
    }

    private func presentFreeText() {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let isJSON = trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
        do {
            let injection: SimulatedInjection
            let ident: String
            switch freeKind {
            case .metar:
                let json = isJSON ? normalizedArray(trimmed) : SimulatedDecode.metarJSON(fromRawLine: trimmed)
                let metar = try SimulatedDecode.parseMetar(json: json)
                ident = metar.stationId
                injection = SimulatedInjection(metars: [metar], taf: nil)
            case .taf:
                // A TAF needs a METAR to render its section — pair a benign scaffold.
                let json = isJSON ? normalizedArray(trimmed) : SimulatedDecode.tafJSON(fromRawLine: trimmed)
                let taf = try SimulatedDecode.parseTaf(json: json)
                ident = taf.stationId
                let scaffold = try SimulatedDecode.parseMetar(json: scaffoldJSON(icao: ident))
                injection = SimulatedInjection(metars: [scaffold], taf: taf)
            }
            let airport = Airport(icao: ident, iata: nil, name: "Free-text paste (SIM)",
                                  latitude: 39.0, longitude: -104.6, elevation: 0, hasMetar: true)
            simPayload = SimPayload(id: "FREE", title: "Free-text \(freeKind.rawValue)", airport: airport, injection: injection)
        } catch {
            errorMessage = "Could not parse pasted \(freeKind.rawValue): \(error.localizedDescription)"
        }
    }

    // Accept either a bare object `{...}` or an array `[{...}]`; the parser decodes an array.
    private func normalizedArray(_ s: String) -> String {
        s.hasPrefix("[") ? s : "[\(s)]"
    }

    private func scaffoldJSON(icao: String) -> String {
        #"[{"icaoId":"\#(icao)","wdir":250,"wspd":6,"visib":"P6SM","temp":20,"dewp":8,"altim":1015,"rawOb":"METAR \#(icao) 251953Z 25006KT P6SM FEW060 20/08 A2998 (SIMULATED SCAFFOLD)","clouds":[{"cover":"FEW","base":6000}],"fltCat":"VFR"}]"#
    }
}

// MARK: - Simulated navigation payload
struct SimPayload: Identifiable, Hashable {
    let id: String
    let title: String
    let airport: Airport
    let injection: SimulatedInjection

    static func == (lhs: SimPayload, rhs: SimPayload) -> Bool { lhs.id == rhs.id && lhs.airport == rhs.airport }
    func hash(into hasher: inout Hasher) { hasher.combine(id); hasher.combine(airport) }
}

// MARK: - Simulated detail screen (wraps the REAL WeatherDetailView with SIMULATED chrome)
struct SimulatedWeatherDetailScreen: View {
    let payload: SimPayload

    var body: some View {
        WeatherDetailView(airport: payload.airport, simulatedInjection: payload.injection)
            .simulatedWeatherChrome()
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    // A genuine pushed sub-screen — proves the SIMULATED marker survives sub-navigation.
                    NavigationLink {
                        SimulatedRawTextScreen(payload: payload)
                    } label: {
                        Image(systemName: "doc.plaintext")
                    }
                }
            }
    }
}

// MARK: - Pushed sub-screen (also carries the SIMULATED chrome)
struct SimulatedRawTextScreen: View {
    let payload: SimPayload

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let metar = payload.injection.metars.first {
                    labeled("Raw METAR", metar.rawText)
                }
                if let taf = payload.injection.taf {
                    labeled("Raw TAF", taf.rawText)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Raw text")
        .navigationBarTitleDisplayMode(.inline)
        .simulatedWeatherChrome()   // pushed sub-screen keeps the banner
    }

    private func labeled(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption.bold()).foregroundColor(.secondary)
            Text(text).font(.system(size: 14).monospaced()).textSelection(.enabled)
        }
    }
}
