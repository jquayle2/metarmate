import SwiftUI
import SwiftData
import CoreLocation

struct WeatherDetailView: View {
    let airport: Airport

    @StateObject private var vm = WeatherViewModel()
    @Query private var favorites: [AirportFavorite]
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var prefs = LayoutPreferences.shared
    @State private var showLayoutSettings = false
    @State private var showNearbyAirports = false

    private var isFavorite: Bool {
        favorites.contains(where: { $0.icao == airport.icao })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if vm.isLoading && vm.metar == nil && vm.advisoryWeather == nil {
                    ProgressView("Loading weather…")
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if let advisory = vm.advisoryWeather {
                    advisoryWeatherView(advisory)
                } else if vm.noWeatherReporting {
                    noReportingView
                } else if let error = vm.error, vm.metar == nil {
                    errorView(error)
                } else {
                    headerSection
                    if let metar = vm.metar {
                        metarSectionsInOrder(metar)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(airport.icao)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 4) {
                    Button {
                        showNearbyAirports = true
                    } label: {
                        Image(systemName: "airplane.circle")
                            .foregroundColor(.secondary)
                    }
                    Button {
                        showLayoutSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundColor(.secondary)
                    }
                    Button(action: toggleFavorite) {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .foregroundColor(isFavorite ? .yellow : .secondary)
                    }
                }
            }
        }
        .sheet(isPresented: $showLayoutSettings) {
            LayoutSettingsView()
        }
        .sheet(isPresented: $showNearbyAirports) {
            NearbyAirportsView(referenceAirport: airport)
        }
        .task {
            await vm.load(airport: airport)
        }
        .task {
            // Auto-refresh every 5 minutes while the view is open
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { break }
                await vm.load(airport: airport)
            }
        }
        .refreshable {
            await vm.load(airport: airport)
        }
    }

    // MARK: - Preference-ordered METAR sections
    @ViewBuilder
    private func metarSectionsInOrder(_ metar: Metar) -> some View {
        let notes = pilotNotes(for: metar, history: vm.metarHistory)
        let hasAmberNote = !notes.isEmpty
        let hasRedNote   = notes.contains(where: { $0.severity == .warning })

        let da = DensityAltitude.calculate(
            temperatureC: Double(metar.temperature),
            dewpointC: Double(metar.dewpoint),
            altimeterInHg: metar.altimeter,
            fieldElevationFt: airport.elevation
        )
        let daAmber = da.hpLossPercent >= 10
        let daRed   = da.hpLossPercent >= 20

        let trendChanging = vm.trend.map { $0.overall != .steady && $0.overall != .unknown } ?? false
        let trendAmber = vm.trend.map { $0.overall != .unknown && $0.overall != .steady } ?? false
        let trendRed   = vm.trend.map { $0.overall == .deteriorating } ?? false

        let verAmber = vm.tafVerification.map { Double($0.categoryAccuracyPct) / 100.0 < 0.80 } ?? false
        let verRed   = vm.tafVerification.map {
            Double($0.categoryAccuracyPct) / 100.0 < 0.60 || $0.significantMisses > 0
        } ?? false

        ForEach(prefs.metarSections) { config in
            switch config.id {
            case .conditions:
                if config.visibility != .hidden {
                    decodedConditionsSection(metar)
                }
            case .rawMetar:
                if config.visibility != .hidden {
                    rawMetarSection(metar)
                }
            case .pilotNotes:
                let showNotes: Bool = {
                    switch config.visibility {
                    case .always:        return true
                    case .amberAndAbove: return hasAmberNote || hasRedNote
                    case .redOnly:       return hasRedNote
                    default:             return false
                    }
                }()
                if showNotes { pilotNotesSection(metar, history: vm.metarHistory) }
            case .performance:
                let showDA: Bool = {
                    switch config.visibility {
                    case .always:        return true
                    case .amberAndAbove: return daAmber || daRed
                    case .redOnly:       return daRed
                    default:             return false
                    }
                }()
                if showDA { densityAltitudeSection(metar) }
            case .trend:
                if let trend = vm.trend {
                    let showTrend: Bool = {
                        switch config.visibility {
                        case .always:        return true
                        case .changingOnly:  return trendChanging
                        case .amberAndAbove: return trendAmber || trendRed
                        case .redOnly:       return trendRed
                        default:             return false
                        }
                    }()
                    if showTrend { trendSection(trend, verification: vm.tafVerification) }
                }
            case .history:
                if vm.metarHistory.count > 1, config.visibility != .hidden {
                    metarHistorySection(vm.metarHistory)
                }
            case .taf:
                if let taf = vm.taf, config.visibility != .hidden {
                    let showRaw = prefs.metarSections.first(where: { $0.id == .rawTaf })?.visibility != .hidden
                    tafSection(taf, showRaw: showRaw)
                }
            case .rawTaf:
                EmptyView()
            case .tafVerification:
                if let verification = vm.tafVerification {
                    let showVer: Bool = {
                        switch config.visibility {
                        case .always:        return true
                        case .amberAndAbove: return verAmber || verRed
                        case .redOnly:       return verRed
                        default:             return false
                        }
                    }()
                    if showVer { tafVerificationSection(verification) }
                }
            default:
                EmptyView()
            }
        }
    }

    // MARK: - Header
    private var headerSection: some View {
        VStack(spacing: 8) {
            Text(airport.name)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                FlightCategoryBadge(category: vm.flightCategory)
                if let metar = vm.metar {
                    observationTimeView(metar)
                }
            }
            if airport.elevation != 0 {
                Text("Elev \(airport.elevation.formatted()) ft MSL")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(cardBackground)
    }

    private func observationTimeView(_ metar: Metar) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let minutes = Int(context.date.timeIntervalSince(metar.observationTime) / 60)
            Text("Observed \(minutes) min ago")
                .font(.caption)
                .foregroundColor(metar.isOld ? Color.red : .secondary)
        }
    }

    // MARK: - Raw METAR
    private func rawMetarSection(_ metar: Metar) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Raw METAR")
            Text(metar.rawText)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.primary)
                .textSelection(.enabled)
        }
        .padding()
        .background(cardBackground)
    }

    // MARK: - Decoded Conditions
    private func decodedConditionsSection(_ metar: Metar) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Conditions")
            conditionRow("wind", "Wind", windText(metar.wind), color: windConditionColor(metar.wind))
            conditionRow("eye.fill", "Visibility", visibilityText(metar.visibility), color: visibilityConditionColor(metar.visibility))
            conditionRow("cloud.fill", "Ceiling", ceilingText(metar), color: ceilingConditionColor(metar.ceilingFeet))
            if !metar.clouds.isEmpty {
                cloudsView(metar.clouds)
            }
            conditionRow("thermometer", "Temp / Dewpoint",
                         "\(metar.temperature)°C / \(metar.dewpoint)°C  (spread \(metar.temperature - metar.dewpoint)°)",
                         color: tempDewConditionColor(temp: metar.temperature, dew: metar.dewpoint))
            conditionRow("gauge", "Altimeter", String(format: "%.2f inHg", metar.altimeter),
                         color: altimeterConditionColor(metar.altimeter))
            if !metar.weatherPhenomena.isEmpty {
                conditionRow("cloud.bolt.rain.fill", "Weather",
                             WeatherDecoder.decodeAll(metar.weatherPhenomena),
                             color: wxPhenomenaConditionColor(metar.weatherPhenomena))
            }
        }
        .padding()
        .background(cardBackground)
    }

    // MARK: - Condition row color helpers

    // Wind: green / amber / orange — never red (red is reserved for IFR flight category)
    private func windConditionColor(_ wind: Wind) -> Color {
        let gust = wind.gust ?? 0
        let speed = wind.speed
        let spread = gust - speed
        if gust >= 20 || speed >= 25 || spread >= 15 { return .orange }
        if gust >= 15 || speed >= 20 || spread >= 10 { return Color(red: 1.0, green: 0.6, blue: 0.0) } // amber
        if speed > 0 { return .green }
        return .primary
    }

    // Visibility: flight category colors — VFR green, MVFR blue, IFR red, LIFR magenta
    private func visibilityConditionColor(_ vis: Double) -> Color {
        if vis < 1 { return Color(red: 0.75, green: 0.0, blue: 0.75) } // LIFR magenta
        if vis < 3 { return .red }                                       // IFR
        if vis < 5 { return Color(red: 0.2, green: 0.5, blue: 1.0) }   // MVFR blue
        return .green                                                     // VFR
    }

    // Ceiling: flight category colors — same scale
    private func ceilingConditionColor(_ ceilingFt: Int?) -> Color {
        guard let c = ceilingFt else { return .green }                   // clear = VFR
        if c < 200  { return Color(red: 0.75, green: 0.0, blue: 0.75) } // LIFR magenta
        if c < 1000 { return .red }                                      // IFR
        if c < 3000 { return Color(red: 0.2, green: 0.5, blue: 1.0) }  // MVFR blue
        return .green                                                     // VFR
    }

    // Temp/dewpoint spread: fog risk — red/amber/green
    private func tempDewConditionColor(temp: Int, dew: Int) -> Color {
        let spread = temp - dew
        if spread <= 2 { return .red }
        if spread <= 4 { return Color(red: 1.0, green: 0.6, blue: 0.0) }
        return .green
    }

    // Altimeter: pressure hazard — amber/orange scale
    private func altimeterConditionColor(_ alt: Double) -> Color {
        if alt < 29.70 { return .orange }
        if alt < 29.80 { return Color(red: 1.0, green: 0.6, blue: 0.0) }
        return .green
    }

    // Weather phenomena: orange for significant, red for TS/FZ (life-safety)
    private func wxPhenomenaConditionColor(_ phenomena: [String]) -> Color {
        let hasTS = phenomena.contains(where: { $0.hasPrefix("TS") || $0.hasPrefix("+TS") || $0.hasPrefix("VCTS") })
        let hasFZ = phenomena.contains(where: { $0.contains("FZ") })
        if hasTS || hasFZ { return .red }
        return .orange
    }

    private func conditionRow(_ icon: String, _ label: String, _ value: String, color: Color = .primary) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(color == .primary ? .secondary : color.opacity(0.8))
                .frame(width: 20)
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .foregroundColor(color)
                .fontWeight(color == .primary || color == .green ? .regular : .semibold)
            Spacer()
        }
    }

    // Cloud layer: per-layer color based on coverage + altitude + CB
    private func cloudLayerColor(_ layer: CloudLayer) -> Color {
        let altFt = layer.altitude * 100
        if layer.isCumulonimbus { return .orange }
        switch layer.coverage {
        case .few, .scattered:
            if altFt < 3000 { return Color(red: 1.0, green: 0.6, blue: 0.0) } // amber — low FEW/SCT
            return .green                                                        // high FEW/SCT benign
        case .broken, .overcast, .verticalVisibility:
            if altFt < 200  { return Color(red: 0.75, green: 0.0, blue: 0.75) } // LIFR magenta
            if altFt < 1000 { return .red }                                      // IFR
            if altFt < 3000 { return Color(red: 0.2, green: 0.5, blue: 1.0) }  // MVFR blue
            return .green
        case .clear, .skyClear:
            return .green
        }
    }

    private func cloudSeverityRank(_ color: Color) -> Int {
        switch color {
        case .orange: return 5
        case .red: return 4
        case _ where color == Color(red: 0.75, green: 0.0, blue: 0.75): return 3 // magenta
        case _ where color == Color(red: 0.2, green: 0.5, blue: 1.0): return 2   // MVFR blue
        case .green: return 1
        default: return 0
        }
    }

    private func cloudsView(_ layers: [CloudLayer]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            let worstColor = layers.map { cloudLayerColor($0) }.max(by: { cloudSeverityRank($0) < cloudSeverityRank($1) }) ?? Color.primary
            Image(systemName: "cloud.fill")
                .foregroundColor(worstColor == .primary ? .secondary : worstColor.opacity(0.8))
                .frame(width: 20)
            Text("Clouds")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(layers.indices, id: \.self) { i in
                    let layer = layers[i]
                    let alt = (layer.altitude * 100).formatted()
                    let layerColor = cloudLayerColor(layer)
                    Text("\(layer.coverage.rawValue) \(alt) ft\(layer.isCumulonimbus ? " CB" : "")")
                        .font(.subheadline)
                        .foregroundColor(layerColor)
                        .fontWeight(layerColor == .green || layerColor == .primary ? .regular : .semibold)
                }
            }
            Spacer()
        }
    }

    // MARK: - Pilot Notes
    private struct PilotNote {
        let icon: String
        let text: String
        let severity: Severity   // .caution (yellow) or .warning (orange)
        enum Severity { case caution, warning }
        var color: Color { severity == .warning ? .orange : Color(red: 1.0, green: 0.6, blue: 0.0) }
    }

    private func pilotNotes(for metar: Metar, history: [Metar]) -> [PilotNote] {
        var notes: [PilotNote] = []
        let wind = metar.wind
        let gust = wind.gust ?? 0
        let speed = wind.speed
        let spread = gust - speed

        // Windshear in remarks
        if let remarks = metar.remarks?.uppercased(), remarks.contains("WS ") || remarks.contains("LLWS") {
            notes.append(.init(icon: "wind", text: "Windshear reported in remarks — check NOTAM and PIREP", severity: .warning))
        }
        // WS in phenomena codes
        if metar.weatherPhenomena.contains(where: { $0.contains("WS") }) {
            notes.append(.init(icon: "wind", text: "Windshear in weather phenomena", severity: .warning))
        }

        // High sustained wind
        if speed >= 25 {
            notes.append(.init(icon: "wind", text: "Sustained \(speed) kt — crosswind likely significant; verify component against aircraft limits", severity: .warning))
        } else if speed >= 20 {
            notes.append(.init(icon: "wind", text: "Sustained \(speed) kt — check crosswind component for your runway", severity: .caution))
        }

        // Gusts — lead with crosswind concern, secondary approach speed tip
        if gust >= 20 {
            notes.append(.init(icon: "wind", text: "Gusts \(gust) kt — check crosswind component for your runway; add \(gust / 2) kt to approach speed", severity: .warning))
        } else if gust >= 15 {
            notes.append(.init(icon: "wind", text: "Gusts \(gust) kt — verify crosswind within limits; consider adding \(gust / 2) kt to approach speed", severity: .caution))
        }

        // Gust spread (turbulence indicator)
        if spread >= 15 {
            notes.append(.init(icon: "tornado", text: "Gust spread \(spread) kt — significant mechanical turbulence likely", severity: .warning))
        } else if spread >= 10 {
            notes.append(.init(icon: "tornado", text: "Gust spread \(spread) kt — moderate turbulence possible", severity: .caution))
        }

        // Variable wind — crosswind unpredictable
        if wind.isVariable && speed >= 8 {
            notes.append(.init(icon: "wind", text: "Variable wind direction at \(speed) kt — crosswind component unpredictable", severity: .caution))
        }

        // Low visibility
        if metar.visibility < 3 {
            notes.append(.init(icon: "eye.slash.fill", text: "Visibility \(String(format: "%g", metar.visibility)) SM — IFR conditions", severity: .warning))
        } else if metar.visibility < 5 {
            notes.append(.init(icon: "eye.slash", text: "Visibility \(String(format: "%g", metar.visibility)) SM — reduced; VFR marginal", severity: .caution))
        }

        // Low ceiling
        if let ceiling = metar.ceilingFeet {
            if ceiling < 500 {
                notes.append(.init(icon: "cloud.fill", text: "Ceiling \(ceiling.formatted()) ft — LIFR", severity: .warning))
            } else if ceiling < 1000 {
                notes.append(.init(icon: "cloud.fill", text: "Ceiling \(ceiling.formatted()) ft — IFR ceiling", severity: .warning))
            } else if ceiling < 3000 {
                notes.append(.init(icon: "cloud", text: "Ceiling \(ceiling.formatted()) ft — below VFR minimums in many areas", severity: .caution))
            }
        }

        // Fog risk: temp/dewpoint spread ≤4° (red at ≤2°, yellow at 3–4°)
        let tempDewSpread = metar.temperature - metar.dewpoint
        if tempDewSpread <= 2 {
            notes.append(.init(icon: "cloud.fog.fill", text: "Temp/dewpoint spread \(tempDewSpread)°C — fog or low stratus imminent", severity: .warning))
        } else if tempDewSpread <= 4 {
            notes.append(.init(icon: "cloud.fog", text: "Temp/dewpoint spread \(tempDewSpread)°C — fog risk; watch for rapid deterioration", severity: .caution))
        }

        // Thunderstorm / CB
        let hasTS = metar.weatherPhenomena.contains(where: { $0.hasPrefix("TS") || $0.hasPrefix("+TS") || $0.hasPrefix("VCTS") })
        let hasCB = metar.clouds.contains(where: { $0.isCumulonimbus })
        if hasTS {
            notes.append(.init(icon: "bolt.fill", text: "Thunderstorm reported — do not depart until clear", severity: .warning))
        } else if hasCB {
            notes.append(.init(icon: "bolt", text: "Cumulonimbus cloud reported — convective activity nearby", severity: .warning))
        }

        // Low altimeter — only flag when pressure is genuinely low, not just below ISA standard
        if metar.altimeter < 29.70 {
            notes.append(.init(icon: "gauge.low", text: "Altimeter \(String(format: "%.2f", metar.altimeter)) inHg — deep low pressure system; check area weather and PIREPs", severity: .warning))
        } else if metar.altimeter < 29.80 {
            notes.append(.init(icon: "gauge", text: "Altimeter \(String(format: "%.2f", metar.altimeter)) inHg — notable low pressure; monitor for developing weather", severity: .caution))
        }

        // Falling altimeter trend from history
        if history.count >= 3 {
            let recent = Array(history.prefix(3))
            let oldest = recent.last!.altimeter
            let newest = recent.first!.altimeter
            let drop = oldest - newest
            if drop >= 0.06 {
                notes.append(.init(icon: "arrow.down.circle.fill", text: String(format: "Altimeter falling %.2f inHg over recent observations — deepening low pressure", drop), severity: .warning))
            } else if drop >= 0.03 {
                notes.append(.init(icon: "arrow.down.circle", text: String(format: "Altimeter dropping %.2f inHg over recent observations — watch for continued deterioration", drop), severity: .caution))
            }
        }

        // Stale data
        if metar.isOld {
            let minutes = Int(Date().timeIntervalSince(metar.observationTime) / 60)
            notes.append(.init(icon: "clock.badge.exclamationmark", text: "Observation is \(minutes) min old — conditions may have changed", severity: .caution))
        }

        // Freezing conditions
        if metar.temperature <= 0 && metar.weatherPhenomena.contains(where: { $0.contains("FZ") || $0.contains("FZRA") }) {
            notes.append(.init(icon: "thermometer.snowflake", text: "Freezing precipitation — icing conditions on aircraft and runway surfaces", severity: .warning))
        } else if metar.temperature <= 2 && metar.temperature - metar.dewpoint <= 3 {
            notes.append(.init(icon: "thermometer.snowflake", text: "Near-freezing with high moisture — frost or freezing precip risk", severity: .caution))
        }

        return notes
    }

    private func pilotNotesSection(_ metar: Metar, history: [Metar]) -> some View {
        let notes = pilotNotes(for: metar, history: history)
        guard !notes.isEmpty else { return AnyView(EmptyView()) }

        return AnyView(
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(notes.contains(where: { $0.severity == .warning }) ? .orange : Color(red: 1.0, green: 0.6, blue: 0.0))
                        .font(.caption)
                    Text("PILOT NOTES")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                        .tracking(1)
                }
                ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: note.icon)
                            .foregroundColor(note.color)
                            .font(.subheadline)
                            .frame(width: 20)
                        Text(note.text)
                            .font(.subheadline)
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("Operational thresholds shown. Verify against your aircraft POH and personal minimums.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.orange.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.orange.opacity(0.25), lineWidth: 1)
                    )
            )
        )
    }

    // MARK: - Density Altitude
    private func densityAltitudeSection(_ metar: Metar) -> some View {
        let da = DensityAltitude.calculate(
            temperatureC: Double(metar.temperature),
            dewpointC: Double(metar.dewpoint),
            altimeterInHg: metar.altimeter,
            fieldElevationFt: airport.elevation
        )
        return VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            statBlock("Density Altitude", da.densityAltitudeText)
                            statBlock("Pressure Altitude", "\(da.pressureAltitudeFt.formatted()) ft MSL")
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 6) {
                            statBlock("ISA Deviation", da.isaDeviationText, rightAlign: true)
                            statBlock("DA Penalty", da.penaltyText, rightAlign: true)
                        }
                    }
                    Divider()
                    HStack(spacing: 8) {
                        Image(systemName: hpLossIcon(da.hpLossPercent))
                            .foregroundColor(hpLossColor(da.hpLossPercent))
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(da.hpLossText)
                                .font(.subheadline.bold())
                                .foregroundColor(hpLossColor(da.hpLossPercent))
                            Text("Normally aspirated engine estimate")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    if let rollText = da.takeoffRollText {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.right.to.line")
                                .foregroundColor(hpLossColor(da.hpLossPercent))
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rollText)
                                    .font(.subheadline.bold())
                                    .foregroundColor(hpLossColor(da.hpLossPercent))
                                Text("Rule of thumb — verify with POH")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    Text(da.summary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PERFORMANCE")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                        .tracking(1)
                    HStack(spacing: 6) {
                        Image(systemName: hpLossIcon(da.hpLossPercent))
                            .foregroundColor(hpLossColor(da.hpLossPercent))
                        Text("\(da.densityAltitudeText)  ·  \(da.hpLossText)")
                            .font(.subheadline.bold())
                            .foregroundColor(hpLossColor(da.hpLossPercent))
                    }
                }
            }
        }
        .padding()
        .background(cardBackground)
    }

    private func statBlock(_ label: String, _ value: String, rightAlign: Bool = false) -> some View {
        VStack(alignment: rightAlign ? .trailing : .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.subheadline.bold())
                .foregroundColor(.primary)
        }
    }

    private func hpLossColor(_ percent: Double) -> Color {
        if percent < 10 { return .green }
        if percent < 20 { return .yellow }
        if percent < 30 { return Color.orange }
        return .red
    }

    private func hpLossIcon(_ percent: Double) -> String {
        if percent < 10 { return "checkmark.circle.fill" }
        if percent < 20 { return "exclamationmark.triangle.fill" }
        if percent < 30 { return "exclamationmark.triangle.fill" }
        return "xmark.octagon.fill"
    }

    // MARK: - Trend
    @State private var trendPulse = false
    @State private var showForecastDetail = false
    @State private var historyExpanded = false
    @State private var tafExpanded = false

    private func trendSection(_ trend: WeatherTrend, verification: TafVerification?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Trend")

            // Alert card — left-edge status strip + prominent deltas
            alertCard(trend)

            Divider()

            // OBSERVED (Point 7 — quantitative, Point 1 — objective labels, Point 4 — no redundant pills)
            Text("OBSERVED")
                .font(.caption2.bold())
                .foregroundColor(.secondary)
                .tracking(0.5)

            let roc = trend.observed.rateOfChange

            // Wind row — always show, with quantitative breakdown when changing
            observedWindRow(trend.observed.wind, roc: roc)

            // Visibility row — only show pill/detail when changing
            if trend.observed.visibility != .steady {
                observedRow(
                    direction: trend.observed.visibility,
                    label: "Visibility",
                    detail: roc?.visibilityQuantitativeText
                )
            } else {
                observedRowSteady(label: "Visibility", span: roc?.spanText)
            }

            // Ceiling row
            if trend.observed.ceiling != .steady {
                observedRow(
                    direction: trend.observed.ceiling,
                    label: "Ceiling",
                    detail: roc?.ceilingQuantitativeText
                )
            } else {
                observedRowSteady(label: "Ceiling", span: roc?.spanText)
            }

            if trend.observed.metarCount > 1 {
                Text(trend.observed.summaryText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Forecast Deviation Strip (Point 3) — TAF vs actual
            if let verification = verification, let strip = forecastDeviationStrip(verification) {
                strip
                Divider()
            }

            // FORECAST
            Text("FORECAST")
                .font(.caption2.bold())
                .foregroundColor(.secondary)
                .tracking(0.5)

            if trend.forecast.overall == .unknown {
                Text("No TAF available for this station.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                TrendIndicator(direction: trend.forecast.wind, label: "Wind")
                TrendIndicator(direction: trend.forecast.visibility, label: "Visibility")
                TrendIndicator(direction: trend.forecast.ceiling, label: "Ceiling")
                Text(trend.forecast.summaryText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(cardBackground)
    }

    // MARK: - Alert Card (Point 2)
    private func alertCard(_ trend: WeatherTrend) -> some View {
        // Use observed trend for the card color/icon — it reflects what's happening NOW.
        // Forecast divergence is called out separately in the summary text.
        let observedOverall = trend.observed.overall
        let color = observedOverall == .unknown ? trend.overall.color : observedOverall.color
        let iconDirection = observedOverall == .unknown ? trend.overall : observedOverall
        let roc = trend.observed.rateOfChange
        let isDeteriorating = observedOverall == .deteriorating

        return HStack(spacing: 0) {
            // Left-edge status strip
            Rectangle()
                .fill(color)
                .frame(width: 4)
                .clipShape(RoundedRectangle(cornerRadius: 2))

            HStack(spacing: 10) {
                // Animated icon — pulses when deteriorating
                Image(systemName: iconDirection.systemImage)
                    .foregroundColor(color)
                    .font(.title2)
                    .scaleEffect(trendPulse ? 1.15 : 1.0)
                    .opacity(trendPulse ? 0.7 : 1.0)
                    .animation(
                        isDeteriorating
                            ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
                            : .default,
                        value: trendPulse
                    )
                    .onAppear { if isDeteriorating { trendPulse = true } }
                    .onChange(of: trend.overall) { trendPulse = (observedOverall == .deteriorating) }

                VStack(alignment: .leading, spacing: 4) {
                    Text(trend.headline)
                        .font(.headline)
                        .foregroundColor(color)

                    // Prominent delta line — most important change front and center
                    if let deltaLine = prominentDeltaLine(trend: trend, roc: roc) {
                        Text(deltaLine)
                            .font(.subheadline.bold())
                            .foregroundColor(.primary)
                    }

                    Text(trend.summaryText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(10)
        }
        .background(color.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(color.opacity(0.2), lineWidth: 1)
        )
        .transition(.asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .opacity
        ))
        .id(observedOverall)
    }

    // Surface the single most actionable delta — wind sustained+gust, ceiling, or vis
    private func prominentDeltaLine(trend: WeatherTrend, roc: RateOfChange?) -> String? {
        guard let roc = roc else { return nil }

        // Ceiling is highest priority
        if trend.observed.ceiling != .steady, let ceilText = roc.ceilingQuantitativeText {
            return ceilText
        }
        // Visibility next
        if trend.observed.visibility != .steady, let visText = roc.visibilityQuantitativeText {
            return visText
        }
        // Wind — show both sustained and gust if changed
        if trend.observed.wind != .steady && roc.hasWindChange {
            return roc.windQuantitativeText
        }
        return nil
    }

    // Wind row with full quantitative breakdown (Point 7)
    private func observedWindRow(_ direction: TrendDirection, roc: RateOfChange?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: direction.systemImage)
                    .foregroundColor(direction.color)
                Text("Wind")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(width: 80, alignment: .leading)
                // Objective label (Point 1) — "Increasing" not "Deteriorating"
                Text(windDirectionLabel(direction))
                    .font(.subheadline.bold())
                    .foregroundColor(direction.color)
            }
            if let roc = roc, roc.hasWindChange {
                Text(roc.windQuantitativeText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 26)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let span = roc?.spanText, (roc?.oldWindKt ?? 0) > 0 || (roc?.newWindKt ?? 0) > 0 {
                Text("No change · \(span)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.leading, 26)
            }
        }
    }

    // Changing parameter row with detail line (Point 7)
    private func observedRow(direction: TrendDirection, label: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: direction.systemImage)
                    .foregroundColor(direction.color)
                Text(label)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(width: 80, alignment: .leading)
                Text(direction.rawValue)
                    .font(.subheadline.bold())
                    .foregroundColor(direction.color)
            }
            if let detail = detail {
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 26)
            }
        }
    }

    // Steady parameter row — compact, no pill clutter (Point 4)
    private func observedRowSteady(label: String, span: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: TrendDirection.steady.systemImage)
                .foregroundColor(.secondary.opacity(0.5))
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(span.map { "Steady · \($0)" } ?? "Steady")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // Objective wind label (Point 1) — no "Deteriorating" judgment
    private func windDirectionLabel(_ direction: TrendDirection) -> String {
        switch direction {
        case .improving: return "Decreasing"
        case .deteriorating: return "Increasing"
        case .steady: return "Steady"
        case .unknown: return "Unknown"
        }
    }

    // MARK: - METAR History
    private func metarHistorySection(_ metars: [Metar]) -> some View {
        let defaultShown = 3
        let totalCount = metars.count
        let displayed = Array(metars.prefix(historyExpanded ? totalCount : defaultShown))
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader("METAR History")
                Spacer()
                if totalCount > defaultShown {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { historyExpanded.toggle() }
                    } label: {
                        Image(systemName: historyExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            ForEach(Array(displayed.enumerated()), id: \.element.id) { index, metar in
                HStack(alignment: .top, spacing: 10) {
                    FlightCategoryBadge(category: metar.flightCategory)
                        .frame(width: 50)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(historyTimeLabel(metar))
                                .font(.caption.bold())
                                .foregroundColor(index == 0 ? .yellow : .primary)
                            if index == 0 {
                                Text("LATEST")
                                    .font(.caption2.bold())
                                    .foregroundColor(.yellow)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .overlay(Capsule().stroke(Color.yellow, lineWidth: 1))
                            }
                        }
                        Text(historyConditionLine(metar))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 2)
                if index < displayed.count - 1 {
                    HStack {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.2))
                            .frame(width: 1, height: 12)
                            .padding(.leading, 24)
                        Spacer()
                    }
                }
            }
        }
        .padding()
        .background(cardBackground)
    }

    private func historyTimeLabel(_ metar: Metar) -> String {
        let localFmt = DateFormatter()
        localFmt.dateFormat = "h:mm a"
        localFmt.timeZone = .current
        let utcFmt = DateFormatter()
        utcFmt.dateFormat = "HH'Z'"
        utcFmt.timeZone = TimeZone(identifier: "UTC")
        return "\(localFmt.string(from: metar.observationTime))  (\(utcFmt.string(from: metar.observationTime)))"
    }

    private func historyConditionLine(_ metar: Metar) -> String {
        var parts: [String] = []
        if let ceil = metar.ceilingFeet {
            let cov = metar.clouds.first(where: { $0.coverage == .broken || $0.coverage == .overcast })?.coverage.rawValue ?? "BKN"
            parts.append("\(cov) \(ceil.formatted()) ft")
        } else {
            parts.append("Clear")
        }
        parts.append("Vis \(visibilityText(metar.visibility))")
        if metar.wind.speed == 0 {
            parts.append("Calm")
        } else {
            let dir = metar.wind.isVariable ? "VRB" : "\(metar.wind.direction ?? 0)°"
            var w = "\(dir) \(metar.wind.speed) kt"
            if let g = metar.wind.gust { w += " G\(g)" }
            parts.append(w)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - TAF
    private func tafSection(_ taf: Taf, showRaw: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeader("TAF")
                if taf.validFrom > Date() {
                    Text("UPCOMING")
                        .font(.caption2.bold())
                        .foregroundColor(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(Capsule().stroke(Color.orange, lineWidth: 1))
                }
                Spacer()
                let totalPeriods = taf.forecasts.count
                if totalPeriods > 3 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { tafExpanded.toggle() }
                    } label: {
                        Image(systemName: tafExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            if showRaw {
                DisclosureGroup("Raw TAF") {
                    Text(taf.rawText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                }
                .font(.subheadline)
                .foregroundColor(.secondary)

                Divider()
            }

            let tafIsUpcoming = taf.validFrom > Date()
            let displayedPeriods = tafExpanded ? taf.forecasts : Array(taf.forecasts.prefix(3))
            ForEach(displayedPeriods) { period in
                tafPeriodRow(period, isCurrent: period.id == taf.currentForecast?.id, isUpcoming: tafIsUpcoming)
            }
        }
        .padding()
        .background(cardBackground)
    }

    private func tafPeriodRow(_ period: TafForecast, isCurrent: Bool, isUpcoming: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(period.flightCategory.swiftUIColor)
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(periodTimeLabel(period))
                        .font(.caption.bold())
                        .foregroundColor(isCurrent ? .yellow : .primary)
                    if isCurrent {
                        Text(isUpcoming ? "NEXT" : "NOW")
                            .font(.caption2.bold())
                            .foregroundColor(isUpcoming ? .orange : .yellow)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay(Capsule().stroke(isUpcoming ? Color.orange : Color.yellow, lineWidth: 1))
                    }
                    Spacer()
                    FlightCategoryBadge(category: period.flightCategory)
                }
                if let wind = period.wind {
                    Text(windText(wind))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let vis = period.visibility {
                    Text("Vis: \(vis >= 6 ? "6+ SM" : "\(String(format: "%g", vis)) SM")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if !period.clouds.isEmpty {
                    Text(period.clouds.map { cloudLayerText($0) }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if !period.weatherPhenomena.isEmpty {
                    Text(WeatherDecoder.decodeAll(period.weatherPhenomena))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .background(isCurrent ? Color.yellow.opacity(0.05) : Color.clear)
        .cornerRadius(6)
    }

    // MARK: - Forecast Deviation Strip (Point 3)
    // Shows where the TAF diverged from reality, using the most recent verification point.
    // Only displayed when divergence exceeds operationally meaningful thresholds.
    private func forecastDeviationStrip(_ verification: TafVerification) -> AnyView? {
        guard let point = verification.points.first else { return nil }

        let windDiv = point.windDivergenceKt
        let ceilDiv = point.ceilingDivergenceFt
        let visDiv = point.visibilityDivergenceSM

        // Build deviation items — only include when threshold exceeded
        var items: [(icon: String, text: String, color: Color)] = []

        // Wind: threshold >5kt
        if let wd = windDiv, abs(wd) > 5 {
            let sign = wd > 0 ? "+" : ""
            let stronger = wd > 0 ? "stronger" : "lighter"
            let color: Color = abs(wd) >= 10 ? .red : Color(red: 1.0, green: 0.6, blue: 0.0)
            items.append(("wind", "Gusts \(sign)\(abs(wd)) kt \(stronger) than forecast", color))
        }

        // Ceiling: threshold >300ft
        if let cd = ceilDiv, abs(cd) > 300 {
            let higher = cd > 0 ? "higher" : "lower"
            let color: Color = abs(cd) >= 800 ? .red : Color(red: 1.0, green: 0.6, blue: 0.0)
            items.append(("cloud.fill", "Ceiling \(abs(cd).formatted()) ft \(higher) than forecast", color))
        } else if point.actualCeilingFt != nil && point.forecastCeilingFt == nil {
            // Ceiling formed when TAF said clear — severity depends on how low
            let ceilFt = point.actualCeilingFt ?? 0
            let color: Color = ceilFt < 1000 ? .red : Color(red: 1.0, green: 0.6, blue: 0.0)
            items.append(("cloud.fill", "Ceiling formed — not forecast", color))
        } else if point.actualCeilingFt == nil && point.forecastCeilingFt != nil {
            items.append(("cloud.fill", "Ceiling cleared — not forecast", .green))
        }

        // Visibility: threshold >0.5SM, ignore when both solidly VFR
        if let vd = visDiv {
            let fcst = point.forecastVisibilitySM ?? 0
            let actual = point.actualVisibilitySM
            let bothVFR = actual > 5.0 && fcst > 5.0
            if !bothVFR && abs(vd) > 0.5 {
                let better = vd > 0 ? "better" : "worse"
                // Better than forecast = green; worse = amber/red
                let color: Color = vd > 0 ? .green : (abs(vd) >= 1.5 ? .red : Color(red: 1.0, green: 0.6, blue: 0.0))
                items.append(("eye.fill", "Visibility \(String(format: "%g", abs(vd))) SM \(better) than forecast", color))
            }
        }

        // On-target items for parameters that were forecast and verified correctly
        let windOnTarget = windDiv.map { abs($0) <= 5 } ?? false
        let ceilOnTarget: Bool = {
            if let cd = ceilDiv { return abs(cd) <= 300 }
            return point.actualCeilingFt == nil && point.forecastCeilingFt == nil
        }()

        if windOnTarget && point.forecastWindKt != nil {
            items.append(("checkmark.circle.fill", "Wind on target", .green))
        }
        if ceilOnTarget && (point.actualCeilingFt != nil || point.forecastCeilingFt != nil) {
            items.append(("checkmark.circle.fill", "Ceiling on target", .green))
        }

        guard !items.isEmpty else { return nil }

        return AnyView(VStack(alignment: .leading, spacing: 6) {
            Text("TAF vs ACTUAL  ·  most recent period")
                .font(.caption2.bold())
                .foregroundColor(.secondary)
                .tracking(0.5)

            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 8) {
                    Image(systemName: item.icon)
                        .foregroundColor(item.color)
                        .font(.caption)
                        .frame(width: 16)
                    Text(item.text)
                        .font(.caption)
                        .foregroundColor(item.color == .green ? .secondary : .primary)
                        .fontWeight(item.color == .green ? .regular : .medium)
                }
            }
        })
    }

    // MARK: - TAF Verification (Forecast Reliability)
    private func tafVerificationSection(_ verification: TafVerification) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()

                    // Per-parameter accuracy grid — only show metrics with scoreable data
                    HStack(spacing: 16) {
                        accuracyCell("Wind", verification.windAccuracyPct, n: verification.windSampleCount)
                        accuracyCell("Ceiling", verification.ceilingAccuracyPct, n: verification.ceilingSampleCount)
                        accuracyCell("Visibility", verification.visibilityAccuracyPct, n: verification.visibilitySampleCount)
                    }

                    // Explainer text
                    VStack(alignment: .leading, spacing: 4) {
                        Text("How this is calculated")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                        Text("Category accuracy counts periods where the TAF's predicted flight category (VFR/MVFR/IFR/LIFR) matched the actual observed category. Individual metrics are only scored when the TAF explicitly forecast that parameter and conditions were operationally significant — missing forecast data is excluded rather than counted as accurate. Thresholds: wind ±7 kt, ceiling ±300 ft, visibility ±0.5 SM.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 2)

                    Divider()

                    Text("RECENT PERIODS")
                        .font(.caption2.bold())
                        .foregroundColor(.secondary)
                        .tracking(0.5)

                    ForEach(verification.points) { point in
                        HStack(spacing: 10) {
                            Image(systemName: point.categoryMatch ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(point.categoryMatch ? .green : .red)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(shortTime(point.observationTime))
                                        .font(.caption.bold())
                                    FlightCategoryBadge(category: point.actualCategory)
                                    if !point.categoryMatch {
                                        Text("fcst \(point.forecastCategory.rawValue)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .overlay(Capsule().stroke(Color.secondary.opacity(0.4), lineWidth: 1))
                                    }
                                }
                                Text(point.divergenceText)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }

                    Text(verification.summary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("FORECAST RELIABILITY")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                            .tracking(1)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(verification.categoryAccuracyPct)%")
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundColor(accuracyColor(verification.categoryAccuracy))
                            Text("category accuracy")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("\(verification.points.count) obs")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        if verification.significantMisses > 0 {
                            Text("\(verification.significantMisses) sig miss\(verification.significantMisses == 1 ? "" : "es")")
                                .font(.caption2.bold())
                                .foregroundColor(.red)
                        } else {
                            Text("No sig misses")
                                .font(.caption2)
                                .foregroundColor(.green)
                        }
                    }
                }
            }
        }
        .padding()
        .background(cardBackground)
    }

    private func accuracyCell(_ label: String, _ pct: Int?, n: Int) -> some View {
        VStack(spacing: 3) {
            if let pct = pct {
                Text("\(pct)%")
                    .font(.subheadline.bold())
                    .foregroundColor(accuracyColor(Double(pct) / 100))
            } else {
                Text("N/A")
                    .font(.subheadline.bold())
                    .foregroundColor(.secondary)
            }
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            if n > 0 {
                Text("\(n) obs")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(.systemGray5).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func accuracyColor(_ accuracy: Double) -> Color {
        if accuracy >= 0.9 { return .green }
        if accuracy >= 0.7 { return .yellow }
        return .red
    }

    private func shortTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        fmt.timeZone = .current
        return fmt.string(from: date)
    }

    // MARK: - Advisory Weather (Open-Meteo, non-METAR airports)
    private func advisoryWeatherView(_ wx: AdvisoryWeather) -> some View {
        VStack(spacing: 16) {
            advisoryHeader(wx)
            advisoryFlightCategoryCard(wx)
            advisorySectionsInOrder(wx)
            advisoryFooter(wx)
        }
    }

    // MARK: - Preference-ordered Advisory sections
    @ViewBuilder
    private func advisorySectionsInOrder(_ wx: AdvisoryWeather) -> some View {
        let advisories = advisoryPilotAdvisories(wx)
        let hasAmber = !advisories.isEmpty
        let hasRed   = advisories.contains(where: { $0.isWarning })

        let daFt    = wx.densityAltitudeFt ?? 0
        let daPenalty = daFt - Double(airport.elevation)
        let daAmber = daPenalty >= 1500
        let daRed   = daPenalty >= 3000

        ForEach(prefs.advisorySections) { config in
            switch config.id {
            case .advConditions:
                if config.visibility != .hidden {
                    advisoryConditionsCard(wx)
                }
            case .advPerformance:
                if wx.densityAltitudeFt != nil {
                    let show: Bool = {
                        switch config.visibility {
                        case .always:        return true
                        case .amberAndAbove: return daAmber || daRed
                        case .redOnly:       return daRed
                        default:             return false
                        }
                    }()
                    if show { advisoryDensityAltitudeCard(wx) }
                }
            case .advPilotAdvisories:
                if !advisories.isEmpty {
                    let show: Bool = {
                        switch config.visibility {
                        case .always:        return true
                        case .amberAndAbove: return hasAmber || hasRed
                        case .redOnly:       return hasRed
                        default:             return false
                        }
                    }()
                    if show { advisoryPilotAdvisoriesCard(advisories) }
                }
            case .advTrends:
                if let trends = wx.trends, config.visibility != .hidden {
                    advisoryTrendsCard(trends)
                }
            case .advForecast:
                if !wx.forecast.isEmpty, config.visibility != .hidden {
                    advisoryForecastStrip(wx.forecast)
                }
            default:
                EmptyView()
            }
        }
    }

    // MARK: - Advisory Header
    private func advisoryHeader(_ wx: AdvisoryWeather) -> some View {
        VStack(spacing: 8) {
            Text(airport.name)
                .font(.title3.bold())
                .multilineTextAlignment(.center)

            // Dashed advisory banner — visually distinct from the official METAR header
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.caption)
                Text("Advisory Weather  ·  Estimated Only")
                    .font(.caption.bold())
                    .foregroundColor(.orange)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundColor(Color.orange.opacity(0.5))
            )

            if airport.elevation != 0 {
                Text("Elev \(airport.elevation.formatted()) ft MSL")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(cardBackground)
    }

    // MARK: - Estimated Flight Category Card
    private func advisoryFlightCategoryCard(_ wx: AdvisoryWeather) -> some View {
        let cat = wx.estimatedFlightCategory
        return HStack(spacing: 14) {
            // Badge with "~" prefix to signal estimation
            ZStack(alignment: .topTrailing) {
                FlightCategoryBadge(category: cat)
                    .scaleEffect(1.4)
                    .padding(.trailing, 4)
                Text("~")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.85))
                    .offset(x: -2, y: -2)
            }
            .frame(width: 64)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("Estimated \(cat.displayName)")
                        .font(.headline)
                        .foregroundColor(cat.swiftUIColor)
                    Text("(~)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text(advisoryFlightCatRationale(wx))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(cat.swiftUIColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
                        .foregroundColor(cat.swiftUIColor.opacity(0.4))
                )
        )
    }

    private func advisoryFlightCatRationale(_ wx: AdvisoryWeather) -> String {
        var parts: [String] = []
        let visMi = wx.visibilityMiles
        if let vis = visMi {
            parts.append("Vis ~\(String(format: "%g", (vis * 2).rounded() / 2)) SM")
        }
        // Only estimate ceiling from cloud cover when visibility is marginal or unknown.
        // When vis >=5 SM, cloud cover % from NWP is unreliable for ceiling inference.
        let visSolidlyVFR = visMi.map { $0 >= 5.0 } ?? false
        if visSolidlyVFR {
            switch wx.cloudCoverPercent {
            case 75...:   parts.append("\(wx.cloudCoverDescription) clouds (ceiling uncertain)")
            case 13...:   parts.append("\(wx.cloudCoverDescription) clouds")
            default:      parts.append("Sky clear")
            }
        } else {
            switch wx.cloudCoverPercent {
            case 75...:    parts.append("OVC ceiling ~1500 ft est.")
            case 50..<75:  parts.append("BKN ceiling ~3000 ft est.")
            case 13..<50:  parts.append("SCT/FEW clouds")
            default:        parts.append("Sky clear")
            }
        }
        return parts.isEmpty ? "Based on estimated visibility and cloud cover" : parts.joined(separator: " · ")
    }

    // MARK: - Advisory Conditions Card
    private func advisoryConditionsCard(_ wx: AdvisoryWeather) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Conditions")

            // Wind
            let windDir = wx.windDirectionDeg.map { "\($0)°" } ?? "Variable"
            let gustStr = wx.windGustKtRounded.map { " G\($0) kt" } ?? ""
            conditionRow("wind", "Wind",
                         "\(windDir)  \(wx.windSpeedKtRounded) kt\(gustStr)",
                         color: advisoryWindColor(wx))

            // Visibility
            if let vis = wx.visibilityMiles {
                conditionRow("eye.fill", "Visibility",
                             String(format: "~%.1f SM", vis),
                             color: visibilityConditionColor(vis))
            }

            // Cloud cover / ceiling
            conditionRow("cloud.fill", "Clouds",
                         "~\(wx.cloudCoverDescription) (\(wx.cloudCoverPercent)%)",
                         color: advisoryCloudColor(wx.cloudCoverPercent))

            // Temp / Dewpoint / Spread
            if let dp = wx.dewpointC, let spread = wx.tdSpreadC {
                conditionRow("thermometer", "Temp / Dewpoint",
                             String(format: "%.0f°C / %.0f°C  (spread %.0f°)",
                                    wx.temperatureC, dp, spread),
                             color: tempDewConditionColor(temp: Int(wx.temperatureC.rounded()),
                                                          dew: Int(dp.rounded())))
                // Fog risk row
                let fogColor: Color = wx.fogRisk == .high ? .red : wx.fogRisk == .moderate ? Color(red:1,green:0.6,blue:0) : .secondary
                if wx.fogRisk != .low {
                    conditionRow("cloud.fog.fill", "Fog Risk",
                                 "~\(wx.fogRisk.rawValue)  (T-D spread \(String(format: "%.0f", spread))°C)",
                                 color: fogColor)
                }
            } else {
                conditionRow("thermometer", "Temperature",
                             String(format: "%.0f°C  (%.0f°F)", wx.temperatureC, wx.temperatureF),
                             color: .primary)
            }

            // Altimeter (estimated) — with explicit accuracy warning
            if let inHg = wx.altimeterInHg {
                VStack(alignment: .leading, spacing: 4) {
                    conditionRow("gauge", "Altimeter (est.)",
                                 String(format: "~%.2f inHg", inHg),
                                 color: altimeterConditionColor(inHg))
                    Text("⚠ Model-derived — may be off ±0.2–0.3 inHg. Use ATIS/ASOS for actual setting.")
                        .font(.caption2)
                        .foregroundColor(.orange)
                        .padding(.leading, 30)
                }
            }

            // Precipitation
            if wx.precipitationMm >= 0.1 {
                let precipColor: Color = wx.precipitationMm >= 4.0 ? .red : wx.precipitationMm >= 1.0 ? Color(red:1,green:0.6,blue:0) : .primary
                conditionRow("cloud.rain.fill", "Precipitation",
                             wx.precipDescription + (wx.precipitationProbability.map { " (\($0)% prob)" } ?? ""),
                             color: precipColor)
            } else if let pct = wx.precipitationProbability, pct >= 30 {
                conditionRow("cloud.rain", "Precip Chance", "\(pct)%",
                             color: pct >= 60 ? Color(red:1,green:0.6,blue:0) : .primary)
            }
        }
        .padding()
        .background(cardBackground)
    }

    // Color helpers for advisory conditions
    private func advisoryWindColor(_ wx: AdvisoryWeather) -> Color {
        let speed = wx.windSpeedKtRounded
        let gust  = wx.windGustKtRounded ?? 0
        if gust >= 20 || speed >= 25 { return .orange }
        if gust >= 15 || speed >= 20 { return Color(red:1,green:0.6,blue:0) }
        if speed > 0 { return .green }
        return .primary
    }

    private func advisoryCloudColor(_ pct: Int) -> Color {
        switch pct {
        case 75...:   return Color(red: 0.2, green: 0.5, blue: 1.0)
        case 50..<75: return Color(red: 0.2, green: 0.5, blue: 1.0)
        case 13..<50: return Color(red: 1.0, green: 0.6, blue: 0.0)
        default:       return .green
        }
    }

    // MARK: - Advisory Density Altitude Card
    private func advisoryDensityAltitudeCard(_ wx: AdvisoryWeather) -> some View {
        guard let daFt = wx.densityAltitudeFt else { return AnyView(EmptyView()) }
        let elevFt  = Double(airport.elevation)
        let penalty = daFt - elevFt
        let hpLoss  = max(0, penalty / 1000.0 * 3.0)

        let daColor: Color = hpLoss < 10 ? .green : hpLoss < 20 ? .yellow : hpLoss < 30 ? .orange : .red
        let daIcon  = hpLoss < 10 ? "checkmark.circle.fill" : hpLoss < 20 ? "exclamationmark.triangle.fill" : "xmark.octagon.fill"

        return AnyView(
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("Performance (estimated)")

                HStack(spacing: 12) {
                    Image(systemName: daIcon)
                        .foregroundColor(daColor)
                        .font(.title3)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(format: "Density Alt ~%.0f ft MSL", daFt))
                            .font(.subheadline.bold())
                            .foregroundColor(daColor)
                        if hpLoss >= 1 {
                            Text(String(format: "~%.0f%% HP loss est. · +%.0f ft above field elev", hpLoss, penalty))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Near standard atmosphere — minimal performance impact")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                }

                Text("Estimated from model pressure and temperature. Verify with POH and official weather.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(cardBackground)
        )
    }

    // MARK: - Advisory Pilot Advisories

    private struct AdvisoryNote: Identifiable {
        let id = UUID()
        let icon: String
        let text: String
        let isWarning: Bool
        var color: Color { isWarning ? .orange : Color(red:1,green:0.6,blue:0) }
    }

    private func advisoryPilotAdvisories(_ wx: AdvisoryWeather) -> [AdvisoryNote] {
        var notes: [AdvisoryNote] = []

        // High density altitude
        if let da = wx.densityAltitudeFt {
            let elevFt = Double(airport.elevation)
            let penalty = da - elevFt
            if penalty >= 3000 {
                notes.append(.init(icon: "arrow.up.to.line", text: String(format: "High density altitude ~%.0f ft — significant power loss, extended takeoff roll expected", da), isWarning: true))
            } else if penalty >= 1500 {
                notes.append(.init(icon: "arrow.up", text: String(format: "Elevated density altitude ~%.0f ft — reduced performance; verify POH", da), isWarning: false))
            }
        }

        // Fog risk
        if let spread = wx.tdSpreadC {
            if spread <= 2 {
                notes.append(.init(icon: "cloud.fog.fill", text: String(format: "T-D spread %.0f°C — fog or low stratus possible; low-level IMC risk", spread), isWarning: true))
            } else if spread <= 4 {
                notes.append(.init(icon: "cloud.fog", text: String(format: "T-D spread %.0f°C — fog risk; watch for rapid deterioration at night or dawn", spread), isWarning: false))
            }
        }

        // Strong gusts
        if let gust = wx.windGustKtRounded, gust >= 20 {
            notes.append(.init(icon: "wind", text: "Gusts ~\(gust) kt estimated — check crosswind component for your runway", isWarning: gust >= 25))
        } else if wx.windSpeedKtRounded >= 20 {
            notes.append(.init(icon: "wind", text: "Sustained wind ~\(wx.windSpeedKtRounded) kt estimated — crosswind likely significant", isWarning: false))
        }

        // Rapid pressure change (falling)
        if let delta = wx.trends?.pressureDeltaHpa, delta <= -2.0 {
            notes.append(.init(icon: "arrow.down.circle.fill", text: String(format: "Pressure falling ~%.1f hPa over 6h — deepening system; check area weather", abs(delta)), isWarning: abs(delta) >= 4))
        }

        // Low visibility
        if let vis = wx.visibilityMiles {
            if vis < 3 {
                notes.append(.init(icon: "eye.slash.fill", text: String(format: "Estimated visibility ~%.1f SM — IFR conditions possible", vis), isWarning: true))
            } else if vis < 5 {
                notes.append(.init(icon: "eye.slash", text: String(format: "Estimated visibility ~%.1f SM — marginal VFR", vis), isWarning: false))
            }
        }

        // High precipitation
        if wx.precipitationMm >= 1.0 {
            notes.append(.init(icon: "cloud.rain.fill", text: "\(wx.precipDescription) estimated — reduced visibility likely", isWarning: wx.precipitationMm >= 4.0))
        }

        return notes
    }

    private func advisoryPilotAdvisoriesCard(_ notes: [AdvisoryNote]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(notes.contains(where: { $0.isWarning }) ? .orange : Color(red:1,green:0.6,blue:0))
                    .font(.caption)
                Text("ESTIMATED ADVISORIES")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                    .tracking(1)
            }
            ForEach(notes) { note in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: note.icon)
                        .foregroundColor(note.color)
                        .font(.subheadline)
                        .frame(width: 20)
                    Text(note.text)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Based on model data — not certified aviation weather. Confirm with official sources.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.top, 2)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.orange.opacity(0.25), lineWidth: 1)
                )
        )
    }

    // MARK: - Advisory Trends Card
    private func advisoryTrendsCard(_ trends: AdvisoryTrends) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("6-Hour Trends (estimated)")

            advisoryTrendRow(
                direction: trends.pressure,
                label: "Pressure",
                delta: trends.pressureDeltaHpa.map { String(format: "%+.1f hPa", $0) }
            )
            advisoryTrendRow(
                direction: trends.windSpeed,
                label: "Wind",
                delta: trends.windDeltaKt.map { String(format: "%+.0f kt", $0) }
            )
            advisoryTrendRow(
                direction: trends.tdSpread,
                label: "T-D Spread",
                delta: trends.tdSpreadDeltaC.map { String(format: "%+.1f°C", $0) }
            )
            advisoryTrendRow(
                direction: trends.visibility,
                label: "Visibility",
                delta: trends.visibilityDeltaKm.map { String(format: "%+.1f km", $0) }
            )

            Text("Trends derived from model history. Pressure ↑ = improving. Wind ↑ = deteriorating.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(cardBackground)
    }

    private func advisoryTrendRow(direction: TrendDirection, label: String, delta: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: direction.systemImage)
                .foregroundColor(direction == .unknown ? .secondary.opacity(0.4) : direction.color)
                .frame(width: 20)
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 88, alignment: .leading)
            if direction != .unknown {
                Text(direction.rawValue)
                    .font(.subheadline.bold())
                    .foregroundColor(direction.color)
            } else {
                Text("—")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            if let delta = delta {
                Spacer()
                Text(delta)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.systemGray5))
                    .clipShape(Capsule())
            }
        }
    }

    // MARK: - Advisory Forecast Strip
    private func advisoryForecastStrip(_ hours: [AdvisoryForecastHour]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader("6-Hour Forecast (estimated)")
                Spacer()
                Button {
                    showForecastDetail = true
                } label: {
                    HStack(spacing: 4) {
                        Text("Expand")
                            .font(.caption)
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(hours) { hour in
                        advisoryForecastChip(hour)
                            .onTapGesture { showForecastDetail = true }
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
            }
        }
        .padding()
        .background(cardBackground)
        .sheet(isPresented: $showForecastDetail) {
            advisoryForecastDetailSheet(hours)
        }
    }

    private func advisoryForecastChip(_ hour: AdvisoryForecastHour) -> some View {
        let cat = hour.estimatedFlightCategory
        let fmt = DateFormatter()
        let _ = { fmt.dateFormat = "h a"; fmt.timeZone = .current }()

        return VStack(spacing: 6) {
            Text(fmt.string(from: hour.time))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            Circle()
                .fill(cat.swiftUIColor)
                .frame(width: 10, height: 10)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 0.5))

            let gStr = hour.windGustKtRounded.map { " G\($0)" } ?? ""
            Text("\(hour.windSpeedKtRounded)\(gStr) kt")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)

            Text("~\(hour.cloudCoverDescription)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            if hour.precipitationMm >= 0.1 {
                Image(systemName: "drop.fill")
                    .font(.system(size: 10))
                    .foregroundColor(Color(red: 0.2, green: 0.5, blue: 1.0))
            } else {
                Color.clear.frame(height: 12)
            }

            Text("\(Int(hour.temperatureC.rounded()))°C")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(width: 70)
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(cat.swiftUIColor.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(cat.swiftUIColor.opacity(0.3), lineWidth: 1))
        )
    }

    // MARK: - Forecast Detail Sheet
    private func advisoryForecastDetailSheet(_ hours: [AdvisoryForecastHour]) -> some View {
        NavigationStack {
            List {
                ForEach(hours) { hour in
                    advisoryForecastDetailRow(hour)
                        .listRowBackground(Color(.systemGray6).opacity(0.2))
                }
                Section {
                    Text("Estimated from model data — not certified aviation weather.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .navigationTitle("6-Hour Forecast")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { showForecastDetail = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func advisoryForecastDetailRow(_ hour: AdvisoryForecastHour) -> some View {
        let cat = hour.estimatedFlightCategory
        let timeFmt = DateFormatter()
        let _ = { timeFmt.dateFormat = "h:mm a"; timeFmt.timeZone = .current }()
        let gStr = hour.windGustKtRounded.map { " G\($0) kt" } ?? ""
        let windDir = hour.windDirectionDeg.map { "\($0)°" } ?? "Variable"
        let visStr = hour.visibilityMiles.map { String(format: "~%.0f SM", $0) } ?? "—"

        return HStack(spacing: 14) {
            // Time + category dot
            VStack(alignment: .leading, spacing: 4) {
                Text(timeFmt.string(from: hour.time))
                    .font(.subheadline.bold())
                    .foregroundColor(.primary)
                HStack(spacing: 4) {
                    Circle()
                        .fill(cat.swiftUIColor)
                        .frame(width: 8, height: 8)
                    Text("Est. \(cat.displayName)")
                        .font(.caption)
                        .foregroundColor(cat.swiftUIColor)
                }
            }
            .frame(width: 90, alignment: .leading)

            Divider()

            // Conditions grid
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 16) {
                    Label("\(windDir)  \(hour.windSpeedKtRounded) kt\(gStr)", systemImage: "wind")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                }
                HStack(spacing: 16) {
                    Label(visStr, systemImage: "eye.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Label("~\(hour.cloudCoverDescription) (\(hour.cloudCoverPercent)%)", systemImage: "cloud.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 16) {
                    Label("\(Int(hour.temperatureC.rounded()))°C", systemImage: "thermometer")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if hour.precipitationMm >= 0.1 {
                        Label(hour.precipDescription, systemImage: "drop.fill")
                            .font(.caption)
                            .foregroundColor(Color(red: 0.2, green: 0.5, blue: 1.0))
                    }
                    if let pHpa = hour.pressureHpa {
                        Label(String(format: "~%.2f inHg", pHpa * 0.02953), systemImage: "gauge")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }

    // MARK: - Advisory Footer
    private func advisoryFooter(_ wx: AdvisoryWeather) -> some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Not certified aviation weather. Use for situational awareness only. Always consult official sources (1800wxbrief, ForeFlight, ATIS) before flight.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(10)
            .background(Color.yellow.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundColor(Color.yellow.opacity(0.4))
            )

            // Open-Meteo attribution (required by CC BY 4.0)
            HStack(spacing: 4) {
                Image(systemName: "network")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Text("Weather data: Open-Meteo.com (CC BY 4.0)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            if let updated = vm.lastUpdated {
                Text("Updated \(updated, style: .relative) ago")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - No Reporting
    private var noReportingView: some View {
        VStack(spacing: 16) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No Weather Reporting")
                .font(.headline)
            Text("\(airport.icao) does not have an active METAR station.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if !vm.nearbyReportingAirports.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("NEARBY REPORTING STATIONS")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                        .tracking(1)
                        .padding(.top, 8)

                    ForEach(vm.nearbyReportingAirports) { item in
                        NavigationLink(destination: WeatherDetailView(airport: item.airport)) {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(item.metar.flightCategory.swiftUIColor)
                                    .frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(item.airport.icao) · \(item.airport.name)")
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    Text(quickWeatherSummary(metar: item.metar))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                let dist = item.airport.distance(from: CLLocation(latitude: airport.latitude, longitude: airport.longitude))
                                Text(dist.distanceNmString)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .padding()
                .background(cardBackground)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    // MARK: - Error
    private func errorView(_ error: Error) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundColor(.yellow)
            Text("Failed to load weather")
                .font(.headline)
            Text(error.localizedDescription)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await vm.load(airport: airport) }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    // MARK: - Helpers
    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(.systemGray6).opacity(0.3))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.bold())
            .foregroundColor(.secondary)
            .tracking(1)
    }

    private func windText(_ wind: Wind) -> String {
        if wind.speed == 0 { return "Calm" }
        let dir = wind.isVariable ? "Variable" : "\(wind.direction ?? 0)°"
        var text = "\(dir) at \(wind.speed) kt"
        if let gust = wind.gust { text += ", gusting \(gust) kt" }
        return text
    }

    private func visibilityText(_ vis: Double) -> String {
        vis >= 10 ? "10+ SM" : "\(String(format: "%g", vis)) SM"
    }

    private func ceilingText(_ metar: Metar) -> String {
        guard let ceiling = metar.ceilingFeet else { return "Clear / No ceiling" }
        let layer = metar.clouds.first(where: { $0.coverage == .broken || $0.coverage == .overcast })
        let coverage = layer?.coverage == .overcast ? "Overcast" : "Broken"
        return "\(coverage) at \(ceiling.formatted()) ft"
    }

    private func periodTimeLabel(_ period: TafForecast) -> String {
        let localFmt = DateFormatter()
        localFmt.dateFormat = "h:mm a"
        localFmt.timeZone = .current

        let utcFmt = DateFormatter()
        utcFmt.dateFormat = "HH'Z'"
        utcFmt.timeZone = TimeZone(identifier: "UTC")

        let localFrom = localFmt.string(from: period.fromTime)
        let localTo = localFmt.string(from: period.toTime)
        let utcFrom = utcFmt.string(from: period.fromTime)
        let utcTo = utcFmt.string(from: period.toTime)

        return "\(localFrom)–\(localTo) (\(utcFrom)–\(utcTo))"
    }

    private func cloudLayerText(_ layer: CloudLayer) -> String {
        if layer.coverage == .clear || layer.coverage == .skyClear || layer.altitude == 0 {
            return layer.coverage.rawValue
        }
        return "\(layer.coverage.rawValue) \((layer.altitude * 100).formatted())"
    }

    private func quickWeatherSummary(metar: Metar) -> String {
        var parts: [String] = []
        let vis = metar.visibility >= 10 ? "10+" : String(format: "%g", metar.visibility)
        parts.append("Vis \(vis) SM")
        if let ceil = metar.ceilingFeet {
            parts.append("Ceil \(ceil.formatted()) ft")
        }
        parts.append("Wind \(metar.wind.speed) kt")
        return parts.joined(separator: " · ")
    }

    private func toggleFavorite() {
        if isFavorite {
            if let fav = favorites.first(where: { $0.icao == airport.icao }) {
                modelContext.delete(fav)
            }
        } else {
            let fav = AirportFavorite(from: airport)
            modelContext.insert(fav)
        }
    }
}
