import SwiftUI
import SwiftData
import CoreLocation

struct WeatherDetailView: View {
    let airport: Airport

    @StateObject private var vm = WeatherViewModel()
    @Query private var favorites: [AirportFavorite]
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var prefs = LayoutPreferences.shared
    @ObservedObject private var store = StoreManager.shared
    @State private var showLayoutSettings = false
    @State private var showNearbyAirports = false
    @State private var showProUpgrade = false     // ASOS paywall
    @State private var showProSheet = false       // Pro paywall (favorites/widgets/Siri)

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
                    if store.isAsosUser, vm.hasASOSData, let obs = vm.synopticLatest {
                        decodedASOSSection(obs)
                    } else if FeatureFlags.asosAvailable, !store.isAsosUser, vm.metar != nil {
                        asosProTeaser
                    }
                    if let metar = vm.metar {
                        metarSectionsInOrder(metar)
                    }
                }
            }
            .padding()
            // Clear the iOS 26 floating tab bar so the last section isn't hidden under it.
            .padding(.bottom, 56)
        }
        .background(IsobarBackground())
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
                    Button {
                        if store.isProUser {
                            toggleFavorite()
                        } else {
                            showProSheet = true
                        }
                    } label: {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .foregroundColor(isFavorite ? Brand.accentOrange : Brand.slate)
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
        .sheet(isPresented: $showProUpgrade) {
            ProUpgradeView(mode: .asos)
        }
        .sheet(isPresented: $showProSheet) {
            ProUpgradeView(mode: .pro)
        }
        .task {
            await vm.load(airport: airport)
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
        // Gate on ABSOLUTE density altitude via the single source of truth (DensityAltitude.swift),
        // NOT HP-loss. Keeps the section's "Red only"/"Amber+" gate in lockstep with the colors.
        let daSev   = daSeverity(densityAltitudeFt: da.densityAltitudeFt)
        let daRed   = daSev == .red
        let daAmber = daSev == .amber || daSev == .red

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
            case .worstRecent:
                // Folded into the METAR History trend brief (historyTrendBrief) — the
                // standalone card is retired; the SectionID/prefs surface is kept (mirrors
                // the .rawTaf no-op precedent) so nothing about a user's saved layout breaks.
                EmptyView()
            default:
                EmptyView()
            }
        }
    }

    // MARK: - Header
    // Station block (badges 1A/2A): orange kicker → heavy station name → status pill,
    // sitting directly on the navy ground.
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            TrackedLabel(text: stationKicker, color: Brand.accentOrange, size: 10, tracking: 3.2)
                .padding(.bottom, 8)
            Text(airport.name)
                .font(.avenir(31, .heavy))
                .foregroundColor(Brand.cloud)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                StatusPill(category: vm.flightCategory)
                if let metar = vm.metar {
                    observationTimeView(metar)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 14)
            if airport.elevation != 0 {
                Text("Elev \(airport.elevation.formatted()) ft MSL")
                    .font(.avenir(12, .demibold))
                    .foregroundColor(Brand.slate)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private var stationKicker: String {
        if let iata = airport.iata, !iata.isEmpty { return "\(airport.icao) · \(iata)" }
        return airport.icao
    }

    // MARK: - ASOS teaser (shown when not subscribed and free period expired)
    private var asosProTeaser: some View {
        Button {
            showProUpgrade = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title3)
                    .foregroundColor(.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ASOS Updates")
                        .font(.subheadline.bold())
                        .foregroundColor(.cyan)
                    Text("Subscribe for 5-minute weather updates between METARs")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.cyan.opacity(0.5))
            }
            .padding()
            .background(Color.cyan.opacity(0.08))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.cyan.opacity(0.2), lineWidth: 1)
            )
        }
    }

    private var canOpenXWCalc: Bool {
        guard let url = URL(string: "xwcalc://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    private func openXWCalc(_ obs: SynopticObservation) {
        var params = "xwcalc://calculate?"
        if let dir = obs.windDirection {
            params += "wind_dir=\(dir)"

            if let best = RunwayService.shared.bestRunway(
                for: airport.icao,
                windDirection: dir,
                windSpeed: obs.windSpeed ?? 0,
                windGust: obs.windGust
            ) {
                let rwyNum = Int(best.runwayEnd.ident.prefix(2)) ?? 0
                if rwyNum > 0 {
                    params += "&runway=\(rwyNum)"
                }
            }
        }
        if let spd = obs.windSpeed {
            params += "&wind_speed=\(Int(spd))"
        }
        if let gust = obs.windGust, gust > (obs.windSpeed ?? 0) {
            params += "&gust=\(Int(gust))"
        } else {
            params += "&gust=0"
        }
        guard let url = URL(string: params) else { return }
        UIApplication.shared.open(url)
    }

    private func asosDataPill(_ text: String, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(text)
                .font(.caption2.monospaced())
        }
        .foregroundColor(.cyan)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.cyan.opacity(0.1))
        .cornerRadius(4)
    }

    // Wind strip showing last ~60 min of 5-min observations
    private var asosWindStrip: some View {
        let recentObs = Array(vm.synopticHistory.suffix(12))
        let maxWind: Double = recentObs.reduce(0) { current, obs in
            max(current, obs.windGust ?? obs.windSpeed ?? 0)
        }
        let barScale = max(maxWind, 10)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("WIND (last 60 min)")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.cyan.opacity(0.6))
                Spacer()
                HStack(spacing: 8) {
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.cyan.opacity(0.7))
                            .frame(width: 8, height: 8)
                        Text("Sust")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.orange.opacity(0.5))
                            .frame(width: 8, height: 8)
                        Text("Gust")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
            }

            HStack(spacing: 2) {
                ForEach(Array(recentObs.enumerated()), id: \.offset) { idx, obs in
                    let spd = Int(obs.windSpeed ?? 0)
                    let gust = obs.windGust.map { Int($0) }
                    let hasGust = (gust ?? 0) > spd
                    let effectiveDir: Int? = obs.windDirection ?? (idx > 0 ? recentObs[idx - 1].windDirection : nil)

                    VStack(spacing: 2) {
                        if let d = effectiveDir, spd > 0 {
                            Text("\(d)°")
                                .font(.system(size: 8))
                                .foregroundColor(.secondary)
                        } else {
                            Text("—")
                                .font(.system(size: 8))
                                .foregroundColor(.secondary.opacity(0.3))
                        }

                        if let d = effectiveDir, spd > 0 {
                            Image(systemName: "location.north.fill")
                                .font(.system(size: 10))
                                .rotationEffect(.degrees(Double(d)))
                                .foregroundColor(.cyan.opacity(min(1.0, 0.3 + Double(spd) / 15.0)))
                        } else if spd == 0 {
                            Circle()
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                .frame(width: 8, height: 8)
                        } else {
                            Image(systemName: "location.north.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.cyan.opacity(0.2))
                        }

                        if hasGust, let g = gust {
                            Text("G\(g)")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(g >= 25 ? .red : g >= 15 ? .orange : .orange.opacity(0.8))
                        } else {
                            Text("\(spd)")
                                .font(.system(size: 10))
                                .foregroundColor(.cyan.opacity(0.8))
                        }

                        ZStack(alignment: .bottom) {
                            if hasGust, let g = gust {
                                let gustH = CGFloat(Double(g) / barScale) * 40
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.orange.opacity(0.25))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 2)
                                            .stroke(Color.orange.opacity(0.4), lineWidth: 1)
                                    )
                                    .frame(height: max(gustH, 2))
                            }
                            let spdH = CGFloat(Double(spd) / barScale) * 40
                            RoundedRectangle(cornerRadius: 2)
                                .fill(spd == 0 ? Color.secondary.opacity(0.2) : Color.cyan.opacity(0.4 + Double(spd) / 25.0))
                                .frame(height: max(spdH, 2))
                        }
                        .frame(height: 40, alignment: .bottom)
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            HStack {
                Text("60m ago")
                Spacer()
                Text("now")
            }
            .font(.system(size: 9))
            .foregroundColor(.secondary.opacity(0.5))
        }
    }

    // Show what changed since the METAR
    @ViewBuilder
    private func asosMetarDelta(_ obs: SynopticObservation, metar: Metar) -> some View {
        let deltas = computeASOSDeltas(obs, metar: metar)
        if !deltas.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("SINCE LAST METAR")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.cyan.opacity(0.6))
                ForEach(deltas, id: \.text) { delta in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: delta.icon)
                            .foregroundColor(delta.color.opacity(0.8))
                            .frame(width: 20)
                        Text(delta.text)
                            .font(.subheadline)
                            .foregroundColor(delta.color)
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private struct ASOSDelta: Hashable {
        let text: String
        let icon: String
        let color: Color

        func hash(into hasher: inout Hasher) { hasher.combine(text) }
        static func == (lhs: ASOSDelta, rhs: ASOSDelta) -> Bool { lhs.text == rhs.text }
    }

    private func computeASOSDeltas(_ obs: SynopticObservation, metar: Metar) -> [ASOSDelta] {
        var deltas: [ASOSDelta] = []

        if let asosSpeed = obs.windSpeed {
            let metarSpeed = Double(metar.wind.speed)
            let diff = Int(asosSpeed) - Int(metarSpeed)
            if abs(diff) >= 5 {
                let color: Color = abs(diff) >= 10 ? .orange : .cyan
                deltas.append(ASOSDelta(text: "Wind \(diff > 0 ? "+" : "")\(diff) kt", icon: "wind", color: color))
            }
        }

        if let asosGust = obs.windGust, asosGust > 0 {
            let metarGust = metar.wind.gust ?? 0
            let diff = Int(asosGust) - metarGust
            if metarGust == 0 {
                deltas.append(ASOSDelta(text: "Gusts developed: \(Int(asosGust)) kt", icon: "wind", color: .orange))
            } else if abs(diff) >= 5 {
                let color: Color = abs(diff) >= 10 ? .orange : .cyan
                deltas.append(ASOSDelta(text: "Gusts \(diff > 0 ? "+" : "")\(diff) kt", icon: "wind", color: color))
            }
        }

        if let asosSpeed = obs.windSpeed, Int(asosSpeed) > 0, metar.wind.speed > 0,
           let asosDir = obs.windDirection, let metarDir = metar.wind.direction {
            var shift = abs(asosDir - metarDir)
            if shift > 180 { shift = 360 - shift }
            if shift >= 30 {
                let color: Color = shift >= 45 ? .orange : .cyan
                deltas.append(ASOSDelta(text: "Wind shifted \(shift)°", icon: "arrow.triangle.2.circlepath", color: color))
            }
        }

        if let asosVis = obs.visibility {
            let diff = asosVis - metar.visibility
            if diff <= -1.0 {
                deltas.append(ASOSDelta(text: String(format: "Visibility %.0f SM (was %.0f)", asosVis, metar.visibility), icon: "eye.fill", color: .orange))
            }
        }

        return deltas
    }

    private func observationTimeView(_ metar: Metar) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let minutes = Int(context.date.timeIntervalSince(metar.observationTime) / 60)
            Text("Observed \(minutes) min ago")
                .font(.avenir(13.5, .demibold))
                .foregroundColor(metar.isOld ? Brand.valueRed : Brand.slate)
        }
    }

    // MARK: - Decoded ASOS Section
    private func decodedASOSSection(_ obs: SynopticObservation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.subheadline)
                    .foregroundColor(.cyan)
                Text("ASOS")
                    .font(.subheadline.bold())
                    .foregroundColor(.cyan)
                    .tracking(1.5)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let minutes = Int(context.date.timeIntervalSince(obs.observationTime) / 60)
                    Text("— \(minutes) min ago")
                        .font(.subheadline)
                        .foregroundColor(.cyan.opacity(0.7))
                }
                Spacer()
                FlightCategoryBadge(category: obs.estimatedCategory)
            }

            if let spd = obs.windSpeed {
                if Int(spd) == 0 {
                    conditionRow("wind", "Wind", "Calm", color: .green)
                } else {
                    let dir = obs.windDirection.map { String(format: "%03d°", $0) } ?? "VRB"
                    let gustText = obs.windGust.map { " gusting \(Int($0)) kt" } ?? ""
                    let wind = Wind(direction: obs.windDirection, speed: Int(spd), gust: obs.windGust.map { Int($0) }, isVariable: obs.windDirection == nil)
                    windConditionRow(wind, value: "\(dir) at \(Int(spd)) kt\(gustText)")
                }
            }

            if let v = obs.visibility {
                let visText = v >= 10 ? "10+ SM" : String(format: "%.1f SM", v)
                conditionRow("eye.fill", "Visibility", visText, color: visibilityConditionColor(v))
            }

            if let ceiling = obs.ceilingAGL {
                let ceilingLayer = obs.cloudLayers.first(where: { $0.coverage == .broken || $0.coverage == .overcast || $0.coverage == .verticalVisibility })
                let coverage = ceilingLayer?.coverage == .overcast ? "Overcast" : "Broken"
                conditionRow("cloud.fill", "Ceiling", "\(coverage) at \(ceiling.formatted()) ft", color: ceilingConditionColor(ceiling))
            }

            if !obs.cloudLayers.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    let worstColor = obs.cloudLayers.map { synopticCloudLayerColor($0) }.max(by: { cloudSeverityRank($0) < cloudSeverityRank($1) }) ?? Color.primary
                    Image(systemName: "cloud.fill")
                        .foregroundColor(worstColor == .primary ? .secondary : worstColor.opacity(0.8))
                        .frame(width: 20)
                    Text("Clouds")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(width: 100, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(obs.cloudLayers.indices, id: \.self) { i in
                            let layer = obs.cloudLayers[i]
                            let layerColor = synopticCloudLayerColor(layer)
                            Text("\(layer.coverage.rawValue) \(layer.altitude.formatted()) ft")
                                .font(.subheadline)
                                .foregroundColor(layerColor)
                                .fontWeight(layerColor == .green || layerColor == .primary ? .regular : .semibold)
                        }
                    }
                    Spacer()
                }
            }

            if let t = obs.temperatureCelsius, let d = obs.dewpointCelsius {
                let spread = t - d
                conditionRow("thermometer", "Temp / Dewpoint",
                             "\(t)°C / \(d)°C  (spread \(spread)°)",
                             color: tempDewConditionColor(temp: t, dew: d))
            }

            if let alt = obs.altimeter {
                conditionRow("gauge", "Altimeter", String(format: "%.2f inHg", alt),
                             color: altimeterConditionColor(alt))
            }

            if let wx = obs.weatherCondition, !wx.isEmpty {
                conditionRow("cloud.bolt.rain.fill", "Weather",
                             WeatherDecoder.decodeAll([wx]),
                             color: wxPhenomenaConditionColor([wx]))
            }

            if !vm.synopticHistory.isEmpty {
                asosWindStrip
            }

            if let metar = vm.metar {
                asosMetarDelta(obs, metar: metar)
            }
        }
        .padding()
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.cyan.opacity(0.3), lineWidth: 1)
        )
    }

    private func synopticCloudLayerColor(_ layer: SynopticCloudLayer) -> Color {
        let altFt = layer.altitude
        switch layer.coverage {
        case .few, .scattered:
            if altFt < 3000 { return Color(red: 1.0, green: 0.6, blue: 0.0) }
            return .green
        case .broken, .overcast, .verticalVisibility:
            if altFt < 200  { return Color(red: 0.75, green: 0.0, blue: 0.75) }
            if altFt < 1000 { return .red }
            if altFt < 3000 { return Color(red: 0.2, green: 0.5, blue: 1.0) }
            return .green
        case .clear, .skyClear:
            return .green
        }
    }

    // MARK: - Raw METAR
    private func rawMetarSection(_ metar: Metar) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Raw METAR")
            Text(metar.rawText)
                .font(.brandMono(11.5, weight: .medium))
                .foregroundColor(Brand.monoDim)
                .textSelection(.enabled)
                .lineSpacing(2)
        }
        .padding()
        .background(cardBackground)
    }

    // MARK: - Decoded Conditions
    private func decodedConditionsSection(_ metar: Metar) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Decoded METAR")
            windConditionRow(metar.wind, value: windText(metar.wind))
            conditionRow("eye.fill", "Visibility", visibilityText(metar.visibility), color: visibilityConditionColor(metar.visibility))
            conditionRow("cloud.fill", "Ceiling", ceilingText(metar), color: ceilingConditionColor(metar.ceilingFeet))
            if !metar.clouds.isEmpty {
                cloudsView(metar.clouds)
            }
            conditionRow("thermometer", "Temp / Dew",
                         "\(metar.temperature)°C / \(metar.dewpoint)°C · Δ\(metar.temperature - metar.dewpoint)",
                         color: tempDewConditionColor(temp: metar.temperature, dew: metar.dewpoint))
            conditionRow("gauge", "Altimeter", String(format: "%.2f inHg", metar.altimeter),
                         color: altimeterConditionColor(metar.altimeter))
            if !metar.weatherPhenomena.isEmpty {
                conditionRow("cloud.bolt.rain.fill", "Weather",
                             WeatherDecoder.decodeAll(metar.weatherPhenomena),
                             color: wxPhenomenaConditionColor(metar.weatherPhenomena))
            }
            // Density Altitude lives in the dedicated Performance section (figure + band +
            // power-loss consequences); not duplicated here. (C2 de-dupe.)
        }
        .padding()
        .background(cardBackground)
    }

    // Decoded-METAR Density Altitude row. Colored by ABSOLUTE-DA severity so it agrees with the
    // Performance card and the section gate. HP-loss % is neutral, informational secondary text.
    private func densityAltitudeRow(_ da: DensityAltitudeResult) -> some View {
        let severity = daSeverity(densityAltitudeFt: da.densityAltitudeFt)
        let color = daSeverityColor(severity)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "airplane.departure")
                .foregroundColor(color == .green ? .secondary : color.opacity(0.8))
                .frame(width: 20)
            Text("Density Altitude")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(da.densityAltitudeText)
                    .font(.subheadline)
                    .foregroundColor(color)
                    .fontWeight(severity == .green ? .regular : .semibold)
                Text("\(da.hpLossText) (normally aspirated)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    // Plain, non-interactive wind row. (Previously a tap target that opened a contextual
    // crosswind calculator seeded from this wind; that affordance was removed — auto crosswind
    // from a METAR now lives only in Pilot Notes, which converts to the magnetic frame.)
    @ViewBuilder
    private func windConditionRow(_ wind: Wind, value: String) -> some View {
        conditionRow("wind", "Wind", value, color: windConditionColor(wind))
    }

    // MARK: - Condition row color helpers

    // Disciplined palette (visual refresh). Gusty/strong wind reads caution; calm/light is good.
    private func windConditionColor(_ wind: Wind) -> Color {
        let gust = wind.gust ?? 0
        let speed = wind.speed
        let spread = gust - speed
        if wind.gust != nil || speed >= 20 || spread >= 10 { return Brand.cautionOrange }
        return Brand.vfrGreen   // calm or light steady → good
    }

    // Visibility: < 3 SM is sub-minimum danger (value red); 3–5 marginal caution; else good.
    private func visibilityConditionColor(_ vis: Double) -> Color {
        ColorRules.visibilityColor(vis)
    }

    // Ceiling: < 1000 IFR danger; < 3000 marginal; clear/high = good.
    private func ceilingConditionColor(_ ceilingFt: Int?) -> Color {
        ColorRules.ceilingColor(ceilingFt)
    }

    // Temp/dewpoint spread: tight spread = fog risk.
    private func tempDewConditionColor(temp: Int, dew: Int) -> Color {
        ColorRules.spreadColor(tempC: temp, dewpointC: dew)
    }

    // Altimeter: genuinely-low pressure reads caution (accent orange); normal is neutral.
    private func altimeterConditionColor(_ alt: Double) -> Color {
        ColorRules.altimeterColor(alt)
    }

    // Present weather: situational caution; TS/FZ escalate to danger.
    private func wxPhenomenaConditionColor(_ phenomena: [String]) -> Color {
        let hasTS = phenomena.contains(where: { $0.hasPrefix("TS") || $0.hasPrefix("+TS") || $0.hasPrefix("VCTS") })
        let hasFZ = phenomena.contains(where: { $0.contains("FZ") })
        if hasTS || hasFZ { return Brand.valueRed }
        return Brand.cautionOrange
    }

    // Decoded row: icon (in value's color) · label (Fog-2) · right-aligned value.
    // Neutral values (Fog) render unremarkable; signal colors get heavier weight.
    private func conditionRow(_ icon: String, _ label: String, _ value: String, color: Color = Brand.fog) -> some View {
        let isNeutral = (color == Brand.fog)
        // Fixed label column keeps values on a consistent left edge; the label WRAPS to
        // multiple lines at large Dynamic Type sizes rather than truncating or shrinking
        // (a label must never render smaller than the value beside it). Top-aligned so
        // wrapped labels and values read cleanly.
        return HStack(alignment: .top, spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .regular))
                .foregroundColor(isNeutral ? Brand.slate : color)
                .frame(width: 20)
            Text(label)
                .font(.avenir(15.5, .demibold))
                .foregroundColor(Brand.fog2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 118, alignment: .leading)
            Text(value)
                .font(.avenir(16, isNeutral ? .demibold : .heavy))
                .foregroundColor(color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // Cloud layer: per-layer color based on coverage + altitude + CB
    private func cloudLayerColor(_ layer: CloudLayer) -> Color {
        let altFt = layer.altitude * 100
        if layer.isCumulonimbus { return Brand.cautionOrange }
        switch layer.coverage {
        case .few, .scattered:
            if altFt < 3000 { return Brand.cautionOrange }  // low FEW/SCT — caution
            return Brand.vfrGreen                            // high FEW/SCT benign
        case .broken, .overcast, .verticalVisibility:
            if altFt < 500  { return Brand.lifrMagenta }     // LIFR
            if altFt < 1000 { return Brand.valueRed }        // IFR
            if altFt < 3000 { return Brand.mvfrBlue }        // MVFR
            return Brand.vfrGreen                            // VFR
        case .clear, .skyClear:
            return Brand.vfrGreen
        }
    }

    private func cloudSeverityRank(_ color: Color) -> Int {
        // LIFR (magenta) is the worst ceiling; CB/low-cloud caution outranks it visually.
        if color == Brand.cautionOrange { return 5 }
        if color == Brand.lifrMagenta   { return 4 }
        if color == Brand.valueRed      { return 3 }
        if color == Brand.mvfrBlue      { return 2 }
        if color == Brand.vfrGreen      { return 1 }
        return 0
    }

    private func cloudsView(_ layers: [CloudLayer]) -> some View {
        HStack(alignment: .top, spacing: 13) {
            let worstColor = layers.map { cloudLayerColor($0) }.max(by: { cloudSeverityRank($0) < cloudSeverityRank($1) }) ?? Brand.vfrGreen
            Image(systemName: "cloud.fill")
                .font(.system(size: 17, weight: .regular))
                .foregroundColor(worstColor)
                .frame(width: 20)
            Text("Clouds")
                .font(.avenir(15.5, .demibold))
                .foregroundColor(Brand.fog2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 118, alignment: .leading)
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
        var crosswind: CrosswindDisplay? = nil   // when set, renders the 3-line crosswind body
        enum Severity { case caution, warning }
        var color: Color {
            if let cw = crosswind { return cw.windColor }   // amber/red wind palette for the icon
            return severity == .warning ? .orange : Color(red: 1.0, green: 0.6, blue: 0.0)
        }
    }

    // MARK: - Crosswind helpers (engine lives in RunwayService — these only adapt types/format)

    /// Structured crosswind display data for a Pilot Notes line. DISPLAY ONLY — every number
    /// comes from RunwayService (magnetic-frame math); this only reads it at two speeds and
    /// formats. `side`/colors are borrowed from the calculator's CrosswindReadout so the two
    /// agree. `line1` is set by the caller (METAR vs TAF-with-timing).
    private struct CrosswindDisplay {
        var line1: String = ""
        let side: String          // calc convention: "L" arrow-before-points-right, "R" arrow-after-points-left
        let xwLow: Int, xwHigh: Int
        let hwLow: Int, hwHigh: Int   // along-track; negative = tailwind (rare on the best runway)
        let isRed: Bool           // gust (high-end) crosswind crosses the calc's red threshold
        let vref: String?
        let ident: String
        /// Calc wind palette: amber by default, red when the gust crosswind crosses the threshold.
        static let amberWind = Color(red: 1.0, green: 0.6, blue: 0.0)
        var windColor: Color { isRed ? .red : Self.amberWind }
    }

    /// Calc red-crosswind threshold (CrosswindKeypadView.severityColor): red at ≥20 kt.
    private static let crosswindRedThreshold = 20

    /// Crosswind/headwind ranges (sustained→gust) for the best runway, plus the runner-up when
    /// it's a genuine near-tie (see RunwayService.bestRunways) — best first, at most two. Selection
    /// runs off the gust (worst case); it's scale-invariant, so the same ends are best at the
    /// sustained speed, which we read for the low end. Empty when calm/variable/no runway data.
    private func crosswindDisplays(_ wind: Wind) -> [CrosswindDisplay] {
        guard !wind.isVariable, let dir = wind.direction, wind.speed > 0 else { return [] }
        let icao = airport.icao
        let speed = Double(wind.speed)
        let hasGust = (wind.gust ?? 0) > wind.speed
        let gustArg = hasGust ? wind.gust.map(Double.init) : nil

        let ranked = RunwayService.shared.bestRunways(
            for: icao, windDirection: dir, windSpeed: speed, windGust: gustArg)
        guard !ranked.isEmpty else { return [] }

        // Sustained-speed components for every end, to read the low end per chosen runway.
        let sustained = RunwayService.shared.crosswinds(
            for: icao, windDirection: dir, windSpeed: speed, windGust: nil)

        return ranked.map { buildCrosswindDisplay($0, sustained: sustained, wind: wind, icao: icao) }
    }

    /// Assemble a CrosswindDisplay for one runway end: the gust-speed components are the high end,
    /// the same end's sustained-speed components the low end. side/colors mirror CrosswindReadout.
    private func buildCrosswindDisplay(_ gustResult: RunwayResult, sustained: [RunwayResult],
                                       wind: Wind, icao: String) -> CrosswindDisplay {
        let ident = RunwayService.shared.displayIdent(gustResult.runwayEnd, icao: icao)
        let sus = sustained.first { $0.runwayEnd.ident == gustResult.runwayEnd.ident } ?? gustResult

        let xwLow = min(sus.crosswind, gustResult.crosswind)
        let xwHigh = max(sus.crosswind, gustResult.crosswind)
        let hwLow = min(sus.headwind, gustResult.headwind)
        let hwHigh = max(sus.headwind, gustResult.headwind)

        // Reuse the calc's RunwayResult.isLeft so the arrow matches CrosswindReadout exactly.
        let side = xwHigh == 0 ? "" : (gustResult.isLeft ? "R" : "L")
        let isRed = xwHigh >= Self.crosswindRedThreshold

        let hasGust = (wind.gust ?? 0) > wind.speed
        let g = wind.gust ?? wind.speed
        let vref: String? = hasGust ? "\(g >= 20 ? "add" : "consider adding") \(g / 2) kt to approach speed" : nil

        return CrosswindDisplay(side: side, xwLow: xwLow, xwHigh: xwHigh,
                                hwLow: hwLow, hwHigh: hwHigh, isRed: isRed, vref: vref, ident: ident)
    }

    private func crosswindXWText(_ cw: CrosswindDisplay) -> String {
        cw.xwLow == cw.xwHigh ? "XW \(cw.xwLow) kt" : "XW \(cw.xwLow)-\(cw.xwHigh) kt"
    }

    private func crosswindAlongText(_ cw: CrosswindDisplay) -> String {
        let lo = cw.hwLow, hi = cw.hwHigh
        if lo >= 0 {
            return lo == hi ? "HW \(lo) kt" : "HW \(lo)-\(hi) kt"
        } else if hi <= 0 {
            let a = abs(hi), b = abs(lo)   // a ≤ b
            return a == b ? "TW \(a) kt" : "TW \(a)-\(b) kt"
        } else {
            return "HW \(lo)-\(hi) kt"
        }
    }

    /// Three-line crosswind body: title, arrow+XW range (amber/red) and HW range (neutral), and a
    /// muted Vref line. Arrow placement mirrors the calculator's CrosswindReadout.
    @ViewBuilder
    private func crosswindNoteBody(_ cw: CrosswindDisplay) -> some View {
        let neutral = Color(white: 0.65)
        VStack(alignment: .leading, spacing: 3) {
            Text(cw.line1)
                .font(.subheadline)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)

            // One line at default sizes; wraps to two at large Dynamic Type.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    crosswindXWGroup(cw)
                    Text(crosswindAlongText(cw)).foregroundColor(neutral)
                }
                VStack(alignment: .leading, spacing: 2) {
                    crosswindXWGroup(cw)
                    Text(crosswindAlongText(cw)).foregroundColor(neutral)
                }
            }
            .font(.subheadline.weight(.semibold))

            if let vref = cw.vref {
                Text(vref)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func crosswindXWGroup(_ cw: CrosswindDisplay) -> some View {
        HStack(spacing: 4) {
            if cw.side == "L" {
                Image(systemName: "arrow.right").foregroundColor(cw.windColor)
            }
            Text(crosswindXWText(cw)).foregroundColor(cw.windColor)
            if cw.side == "R" {
                Image(systemName: "arrow.left").foregroundColor(cw.windColor)
            }
        }
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

        // Crosswind — one consolidated note showing the sustained→gust range on the best runway.
        // Triggers on a notable sustained wind or any gust crossing the caution threshold.
        let hasGust = gust > speed
        if speed >= 20 || gust >= 15 {
            let severity: PilotNote.Severity = (speed >= 25 || gust >= 20) ? .warning : .caution
            let displays = crosswindDisplays(wind)
            if !displays.isEmpty {
                // Best runway first; a near-tie runner-up follows with subtler "or RWY" framing.
                for (i, display) in displays.enumerated() {
                    var cw = display
                    if i == 0 {
                        let lead = hasGust ? "Gusts \(gust) kt" : "Wind \(speed) kt"
                        cw.line1 = "\(lead) — RWY \(cw.ident)"
                    } else {
                        cw.line1 = "or RWY \(cw.ident)"
                    }
                    notes.append(.init(icon: "wind", text: cw.line1, severity: severity, crosswind: cw))
                }
            } else {
                let lead = hasGust ? "Gusts \(gust) kt" : "Sustained \(speed) kt"
                let vref = hasGust ? "; \(gust >= 20 ? "add" : "consider adding") \(gust / 2) kt to approach speed" : ""
                notes.append(.init(icon: "wind", text: "\(lead) — check crosswind component for your runway\(vref)", severity: severity))
            }
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
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    WeatherFrontTriangle(color: Brand.accentOrange, size: 14)
                    TrackedLabel(text: "Pilot Notes", color: Brand.accentOrange, size: 10.5, tracking: 2.6)
                }
                ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                    HStack(alignment: .top, spacing: 11) {
                        Image(systemName: note.icon)
                            .foregroundColor(note.color)
                            .font(.subheadline)
                            .frame(width: 20)
                        if let cw = note.crosswind {
                            crosswindNoteBody(cw)
                        } else {
                            Text(note.text)
                                .font(.avenir(14.5, .demibold))
                                .foregroundColor(Brand.fog)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Text("Operational thresholds shown. Verify against your aircraft POH and personal minimums.")
                    .font(.caption2)
                    .foregroundColor(Brand.slate)
                    .padding(.top, 2)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: Brand.cardRadius, style: .continuous)
                    .fill(LinearGradient(colors: [Brand.pilotNotesTop, Brand.pilotNotesBottom],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(
                        RoundedRectangle(cornerRadius: Brand.cardRadius, style: .continuous)
                            .stroke(Brand.pilotNotesBorder, lineWidth: 1)
                    )
            )
        )
    }

    // MARK: - Density Altitude
    // nil = follow the auto default (expanded at amber/red); once the user taps, their choice sticks.
    @State private var performanceExpandedOverride: Bool? = nil

    private func densityAltitudeSection(_ metar: Metar) -> some View {
        let da = DensityAltitude.calculate(
            temperatureC: Double(metar.temperature),
            dewpointC: Double(metar.dewpoint),
            altimeterInHg: metar.altimeter,
            fieldElevationFt: airport.elevation
        )
        let severity = daSeverity(densityAltitudeFt: da.densityAltitudeFt)
        let color = daSeverityColor(severity)
        let icon  = daSeverityIcon(severity)
        // Auto-expand when amber or above; collapsed when green. User taps override the default.
        let expanded = Binding(
            get: { performanceExpandedOverride ?? (severity != .green) },
            set: { performanceExpandedOverride = $0 }
        )
        return VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup(isExpanded: expanded) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            statBlock("Density Altitude", da.densityAltitudeText, valueColor: color)
                            statBlock("Pressure Altitude", "\(da.pressureAltitudeFt.formatted()) ft MSL")
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 6) {
                            statBlock("ISA Deviation", da.isaDeviationText, rightAlign: true)
                            statBlock("DA Penalty", da.penaltyText, rightAlign: true)
                        }
                    }
                    Divider()
                    // HP-loss is INFORMATIONAL secondary text — neutral, never drives the color.
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.slash")
                            .foregroundColor(.secondary)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(da.hpLossText) est.")
                                .font(.subheadline.bold())
                                .foregroundColor(.secondary)
                            Text("Normally aspirated engine — informational only")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    if let rollText = da.takeoffRollText {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.right.to.line")
                                .foregroundColor(.secondary)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rollText)
                                    .font(.subheadline.bold())
                                    .foregroundColor(.secondary)
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
                    Text("Rule-of-thumb advisory — not a go/no-go limit. Verify against your aircraft POH and personal minimums.")
                        .font(.caption2)
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
                        Image(systemName: icon)
                            .foregroundColor(color)
                        Text(da.densityAltitudeText)
                            .font(.subheadline.bold())
                            .foregroundColor(color)
                        Text("·  \(da.hpLossText) (NA)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(cardBackground)
    }

    private func statBlock(_ label: String, _ value: String, rightAlign: Bool = false, valueColor: Color = .primary) -> some View {
        VStack(alignment: rightAlign ? .trailing : .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.subheadline.bold())
                .foregroundColor(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    // Density-altitude severity → color/icon. Keyed to ABSOLUTE DA via daSeverity (the single
    // source of truth). THREE bands only: green / amber / red. Wind-axis discipline — distinct,
    // labeled performance metric, NOT flight category and NOT go/no-go.
    private func daSeverityColor(_ severity: DASeverity) -> Color {
        switch severity {
        case .green: return .green
        case .amber: return Color(red: 1.0, green: 0.6, blue: 0.0)
        case .red:   return .red
        }
    }

    private func daSeverityIcon(_ severity: DASeverity) -> String {
        switch severity {
        case .green: return "checkmark.circle.fill"
        case .amber: return "exclamationmark.triangle.fill"
        case .red:   return "xmark.octagon.fill"
        }
    }

    // MARK: - Trend
    @State private var trendPulse = false
    @State private var showForecastDetail = false
    @State private var historyExpanded = false
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
        let isMixed = trend.headline.hasPrefix("Mixed")
        let direction = isMixed ? TrendDirection.steady : (observedOverall == .unknown ? trend.overall : observedOverall)
        let roc = trend.observed.rateOfChange
        let isDeteriorating = observedOverall == .deteriorating && !isMixed
        let style = ColorRules.trendStyle(direction)
        let headlineColor = isDeteriorating ? Brand.valueRed : Brand.cloud

        return HStack(spacing: 16) {
            // Signature trend mark — up/orange for improving-stable, down/red for deteriorating.
            TrendArrowView(up: style.up, color: style.color)

            VStack(alignment: .leading, spacing: 4) {
                Text(trend.headline)
                    .font(.avenir(15, .heavy))
                    .foregroundColor(headlineColor)

                if let deltaLine = prominentDeltaLine(trend: trend, roc: roc) {
                    Text(deltaLine)
                        .font(.brandMono(15, weight: .bold))
                        .foregroundColor(Brand.cloud)
                }

                Text(trend.summaryText)
                    .font(.avenir(12.5, .demibold))
                    .foregroundColor(Brand.slate)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isDeteriorating
                      ? AnyShapeStyle(LinearGradient(colors: [Brand.alertTop, Brand.alertBottom],
                                                     startPoint: .top, endPoint: .bottom))
                      : AnyShapeStyle(Brand.cardFill))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isDeteriorating ? Brand.alertBorder : Brand.cardBorder, lineWidth: 1)
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

        // Match the headline priority: ceiling first, then visibility, then wind
        // If a category is non-steady, show its delta even if text is sparse — don't fall through to a conflicting metric
        if trend.observed.ceiling != .steady {
            return roc.ceilingQuantitativeText
        }
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
        let pressure = HistoryRules.pressureTrend(from: metars)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                sectionHeader("METAR History")
                Spacer()
                Text(historyWindowTag(metars))
                    .font(.brandMono(10.5, weight: .bold))
                    .foregroundColor(Brand.monoDim2)
                if totalCount > defaultShown {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { historyExpanded.toggle() }
                    } label: {
                        Image(systemName: historyExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundColor(Brand.slate)
                    }
                }
            }

            historyTrendBrief(metars, pressure: pressure)
                .font(.avenir(18, .heavy))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            if let pressure = pressure {
                pressureTrendCard(pressure)
            }

            if metars.count >= 2 {
                windHistoryStrip(metars)
            }

            VStack(alignment: .leading, spacing: 2) {
                TrackedLabel(text: "Observations", size: 10.5, tracking: 2.4)
                    .padding(.bottom, 2)
                ForEach(Array(displayed.enumerated()), id: \.element.id) { index, metar in
                    historyObsRow(metar, isLatest: index == 0)
                    if index < displayed.count - 1 {
                        HStack {
                            Rectangle()
                                .fill(Brand.rowDivider)
                                .frame(width: 1, height: 12)
                                .padding(.leading, 12)
                            Spacer()
                        }
                    }
                }
            }
        }
        .padding()
        .background(cardBackground)
    }

    private func historyWindowTag(_ metars: [Metar]) -> String {
        guard metars.count >= 2,
              let newest = metars.first?.observationTime,
              let oldest = metars.last?.observationTime else { return "—" }
        let hrs = max(1, Int((newest.timeIntervalSince(oldest) / 3600).rounded()))
        return "\(hrs) HR"
    }

    // Plain-English recent-trend lead: a falling-pressure lead (amber, or red if rapid) takes
    // priority since it's the earliest hint of deterioration; otherwise a neutral category
    // lead. The worst-recent extreme folds in as a trailing clause only when the current
    // sample no longer reflects it (Decision 6).
    private func historyTrendBrief(_ metars: [Metar], pressure: PressureTrend?) -> Text {
        guard let latest = metars.first else {
            return Text("No recent observations.").foregroundColor(Brand.slate)
        }

        let lead: Text
        if let pressure = pressure, pressure.state == .falling {
            let label = pressure.isRapid ? "Pressure falling rapidly. " : "Pressure falling. "
            lead = Text(label).foregroundColor(pressure.isRapid ? Brand.dangerRed : Brand.cautionOrange)
        } else {
            lead = Text("\(latest.flightCategory.rawValue). ").foregroundColor(Brand.cloud)
        }

        var tail: String
        if let oldest = metars.last,
           oldest.wind.speed != latest.wind.speed || oldest.wind.gust != latest.wind.gust {
            tail = "Wind \(tafCompactWind(oldest.wind)) to \(tafCompactWind(latest.wind)) over the last \(historyWindowPhrase(metars))."
        } else {
            tail = "Steady over the last \(historyWindowPhrase(metars))."
        }

        if let stats = worstRecentStats(metars), stats.hasRed || stats.hasAmber {
            let stillCurrent = latest.wind.gust == stats.maxGust && latest.wind.speed == stats.maxSustained
            if !stillCurrent {
                if let gust = stats.maxGust, gust >= 15 {
                    tail += " Gusts to \(gust) kt earlier."
                } else if let ceil = stats.minCeilingFt, ceil < (latest.ceilingFeet ?? Int.max) {
                    tail += " Ceiling as low as \(ceil.formatted()) ft earlier."
                } else if stats.minVisSM < latest.visibility {
                    tail += " Vis as low as \(String(format: "%g", stats.minVisSM)) SM earlier."
                }
            }
        }

        return lead + Text(tail).foregroundColor(Brand.slate)
    }

    private func historyWindowPhrase(_ metars: [Metar]) -> String {
        guard let newest = metars.first?.observationTime, let oldest = metars.last?.observationTime else { return "period" }
        let hrs = newest.timeIntervalSince(oldest) / 3600
        return hrs < 1.5 ? "hour" : "\(Int(hrs.rounded())) hrs"
    }

    // MARK: - Pressure trend card (leading indicator)

    private func pressureTrendCard(_ pressure: PressureTrend) -> some View {
        let isFalling = pressure.state == .falling
        let accent: Color = pressure.isRapid ? Brand.dangerRed
            : (isFalling ? Brand.cautionOrange : (pressure.state == .rising ? Brand.vfrGreen : Brand.slate))
        let stateLabel = pressure.isRapid ? "Falling rapidly" : (isFalling ? "Falling" : (pressure.state == .rising ? "Rising" : "Steady"))
        let spanText = pressure.spanHours < 1
            ? "\(Int((pressure.spanHours * 60).rounded())) min"
            : "\(String(format: "%.1f", pressure.spanHours)) hr"
        let sign = pressure.deltaInHg > 0 ? "+" : ""
        let deltaText = "\(sign)\(String(format: "%.2f", pressure.deltaInHg)) / \(spanText)"

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 7) {
                    Image(systemName: "gauge").font(.system(size: 13)).foregroundColor(accent)
                    Text("Pressure")
                        .font(.avenir(10.5, .heavy))
                        .tracking(2.0)
                        .foregroundColor(accent)
                }
                Spacer()
                Text(stateLabel)
                    .font(.avenir(12, .heavy))
                    .foregroundColor(accent)
            }
            HStack(alignment: .lastTextBaseline, spacing: 14) {
                Text(String(format: "%.2f", pressure.currentAltimeter))
                    .font(.brandMono(30, weight: .bold))
                    .foregroundColor(Brand.cloud)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Text(deltaText)
                    .font(.brandMono(13, weight: .bold))
                    .foregroundColor(accent)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer()
                if pressure.sparklineValues.count >= 2 {
                    PressureSparkline(values: pressure.sparklineValues, color: accent)
                        .frame(width: 84)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Group {
                if isFalling {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(colors: [accent.opacity(0.08), accent.opacity(0.02)],
                                             startPoint: .top, endPoint: .bottom))
                } else {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.22))
                }
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isFalling ? accent.opacity(0.3) : Brand.cardBorder, lineWidth: 1)
        )
    }

    // MARK: - Wind adaptive strip (backward, matches the TAF hero's grammar — Decision 2)

    private func windHistoryStrip(_ metars: [Metar]) -> some View {
        // Oldest-first, capped to the most recent 6 samples, flowing into a highlighted NOW.
        let ordered = Array(metars.reversed().suffix(6))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                ForEach(Array(ordered.enumerated()), id: \.offset) { idx, metar in
                    WindHistoryColumn(
                        timeLabel: idx == ordered.count - 1 ? "Now" : historyStripTimeLabel(metar.observationTime),
                        wind: metar.wind,
                        isNow: idx == ordered.count - 1
                    )
                    if idx < ordered.count - 1 { Spacer(minLength: 0) }
                }
            }
            CategoryRibbon(segments: ordered.enumerated().map { idx, metar in
                CategoryRibbon.Segment(
                    color: ColorRules.windCodeColor(metar.wind),
                    weight: 1.0,
                    isCurrent: idx == ordered.count - 1
                )
            })
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black.opacity(0.22)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Brand.cardBorder, lineWidth: 1))
    }

    private func historyStripTimeLabel(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH'Z'"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: date)
    }

    // Glyph + value + time column for the History wind strip — mirrors ForecastStripColumn's
    // shape but is wind-only (no limitingFactor needed backward), driven by ColorRules.windColor.
    private struct WindHistoryColumn: View {
        let timeLabel: String
        let wind: Wind
        var isNow: Bool = false

        var body: some View {
            let color = ColorRules.windCodeColor(wind)
            VStack(spacing: 4) {
                WindBarbGlyph(directionDeg: (wind.isVariable || wind.speed == 0) ? nil : wind.direction,
                             color: color, size: isNow ? 26 : 20)
                Text(wind.speed == 0 ? "Calm" : "\(wind.speed)\(wind.gust.map { "G\($0)" } ?? "")")
                    .font(.brandMono(isNow ? 13 : 12, weight: .semibold))
                    .foregroundColor(isNow ? Brand.cloud : color)
                Text(timeLabel.uppercased())
                    .font(.avenir(9.5, .heavy))
                    .tracking(0.6)
                    .foregroundColor(isNow ? Brand.accentOrange : Brand.monoDim2)
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            }
            .frame(minWidth: 44)
        }
    }

    // MARK: - Raw observations list (unchanged data/logic, Brand-token chrome, altimeter added)

    @ViewBuilder
    private func historyObsRow(_ metar: Metar, isLatest: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(ColorRules.flightCategoryColor(metar.flightCategory).opacity(isLatest ? 1.0 : 0.5))
                .frame(width: 3)
                .clipShape(Capsule())
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(historyTimeLabel(metar))
                        .font(.avenir(isLatest ? 14.5 : 13.5, isLatest ? .heavy : .bold))
                        .foregroundColor(isLatest ? Brand.cloud : Brand.fog)
                    if isLatest {
                        Text("LATEST")
                            .font(.avenir(9, .heavy))
                            .tracking(0.6)
                            .foregroundColor(Brand.accentOrange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay(Capsule().stroke(Brand.accentOrange.opacity(0.5), lineWidth: 1))
                    }
                    Spacer()
                    if isLatest {
                        Text(metar.flightCategory.rawValue)
                            .font(.avenir(10.5, .heavy))
                            .foregroundColor(ColorRules.flightCategoryColor(metar.flightCategory))
                    }
                }
                Text(isLatest ? historyConditionLine(metar) : historyConditionLineCompact(metar))
                    .font(.brandMono(12.5, weight: .medium))
                    .foregroundColor(Brand.monoDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, isLatest ? 12 : 4)
        .padding(.vertical, isLatest ? 10 : 4)
        .background(
            isLatest
                ? AnyView(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Brand.accentOrange.opacity(0.06)))
                : AnyView(Color.clear)
        )
        .overlay(
            isLatest
                ? AnyView(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Brand.accentOrange.opacity(0.3), lineWidth: 1))
                : AnyView(EmptyView())
        )
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

    // Full decoded line for the latest observation: ceiling · vis · wind · altimeter.
    private func historyConditionLine(_ metar: Metar) -> String {
        var parts: [String] = []
        if let ceil = metar.ceilingFeet {
            let cov = metar.clouds.first(where: { $0.coverage == .broken || $0.coverage == .overcast })?.coverage.rawValue ?? "BKN"
            parts.append("\(cov) \(ceil.formatted()) ft")
        } else {
            parts.append("Clear")
        }
        parts.append("Vis \(visibilityText(metar.visibility))")
        parts.append(tafCompactWind(metar.wind))
        parts.append(metarAltimeterCode(metar.altimeter))
        return parts.joined(separator: " · ")
    }

    // Compact line for older observations: wind · altimeter only, so a pressure drop is
    // traceable (A2978 → A2985 → A2992) without repeating ceiling/vis every row.
    private func historyConditionLineCompact(_ metar: Metar) -> String {
        "\(tafCompactWind(metar.wind)) · \(metarAltimeterCode(metar.altimeter))"
    }

    // METAR-style altimeter group, e.g. 29.78 inHg -> "A2978".
    private func metarAltimeterCode(_ inHg: Double) -> String {
        "A" + String(format: "%04.0f", (inHg * 100).rounded())
    }

    // MARK: - Worst Recent Conditions
    // Scans METAR history for the extremes — answers "Has it been worse recently?" Retained
    // as a pure data source; the standalone card was retired (Decision 6) and its signal now
    // folds into historyTrendBrief above. Only surfaces items that are operationally notable,
    // not calm-VFR noise.
    private struct WorstRecentStats {
        let maxGust: Int?
        let maxSustained: Int
        let minCeilingFt: Int?
        let minVisSM: Double
        let worstCategory: FlightCategory
        let spanHours: Double
        let obsCount: Int

        var hasRed: Bool {
            if let ceil = minCeilingFt, ceil < 1000 { return true }
            if minVisSM < 3.0 { return true }
            if (maxGust ?? 0) >= 25 || maxSustained >= 25 { return true }
            if worstCategory == .ifr || worstCategory == .lifr { return true }
            return false
        }

        var hasAmber: Bool {
            if let ceil = minCeilingFt, ceil < 3000 { return true }
            if minVisSM < 5.0 { return true }
            if (maxGust ?? 0) >= 15 || maxSustained >= 20 { return true }
            if worstCategory == .mvfr { return true }
            return false
        }

        var hasNotableItems: Bool { hasAmber || hasRed }
    }

    private func worstRecentStats(_ metars: [Metar]) -> WorstRecentStats? {
        guard metars.count >= 2 else { return nil }
        let maxGust = metars.compactMap { $0.wind.gust }.max()
        let maxSustained = metars.map { $0.wind.speed }.max() ?? 0
        let minCeiling = metars.compactMap { $0.ceilingFeet }.min()
        let minVis = metars.map { $0.visibility }.min() ?? 10.0
        let worstCat = metars.map { $0.flightCategory }.min(by: { categoryRank($0) < categoryRank($1) }) ?? .vfr
        let spanHours: Double = {
            guard let newest = metars.first?.observationTime,
                  let oldest = metars.last?.observationTime else { return 0 }
            return newest.timeIntervalSince(oldest) / 3600
        }()
        let stats = WorstRecentStats(maxGust: maxGust, maxSustained: maxSustained, minCeilingFt: minCeiling, minVisSM: minVis, worstCategory: worstCat, spanHours: spanHours, obsCount: metars.count)
        return stats.hasNotableItems ? stats : nil
    }

    private func categoryRank(_ cat: FlightCategory) -> Int {
        switch cat {
        case .vfr: return 0
        case .mvfr: return 1
        case .ifr: return 2
        case .lifr: return 3
        default: return 0
        }
    }

    // MARK: - TAF
    private func tafSection(_ taf: Taf, showRaw: Bool = true) -> some View {
        let tafIsUpcoming = taf.validFrom > Date()
        let validHours = max(1, Int(taf.validTo.timeIntervalSince(taf.validFrom) / 3600))

        return VStack(alignment: .leading, spacing: 8) {

            // Adaptive hero — brief, per-period limiting-factor row, category ribbon.
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    sectionHeader("Forecast · TAF")
                    Spacer()
                    if tafIsUpcoming {
                        Text("UPCOMING")
                            .font(.avenir(9, .heavy))
                            .tracking(1.0)
                            .foregroundColor(Brand.cautionOrange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .overlay(Capsule().stroke(Brand.cautionOrange.opacity(0.5), lineWidth: 1))
                    }
                    Text("\(validHours) HR")
                        .font(.brandMono(10.5, weight: .bold))
                        .foregroundColor(Brand.monoDim2)
                }
                tafHeroBrief(taf)
                    .font(.avenir(18, .heavy))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                if !taf.baseForecasts.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            ForEach(taf.baseForecasts) { period in
                                ForecastStripColumn(
                                    timeLabel: tafStripTimeLabel(period.fromTime),
                                    factor: ForecastRules.limitingFactor(for: period),
                                    isHighlighted: period.id == taf.currentForecast?.id
                                )
                            }
                        }
                        .padding(.horizontal, 2)
                        .padding(.vertical, 2)
                    }

                    CategoryRibbon(segments: taf.baseForecasts.map { period in
                        let duration = max(period.toTime.timeIntervalSince(period.fromTime), 60)
                        // Ribbon collapses to 3 colors (green/blue/red) — LIFR folds into IFR red.
                        let ribbonCategory: FlightCategory = period.flightCategory == .lifr ? .ifr : period.flightCategory
                        return CategoryRibbon.Segment(
                            color: ColorRules.flightCategoryColor(ribbonCategory),
                            weight: duration,
                            isCurrent: period.id == taf.currentForecast?.id
                        )
                    })
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(cardBackground)

            // Delta cards — one per period, treatment keyed by category (Decision 4).
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(taf.baseForecasts.enumerated()), id: \.element.id) { idx, period in
                    tafDeltaCard(
                        period,
                        previous: idx > 0 ? taf.baseForecasts[idx - 1] : nil,
                        tag: tafRelativeTag(period,
                                            isCurrent: period.id == taf.currentForecast?.id,
                                            tafIsUpcoming: tafIsUpcoming)
                    )
                }
            }

            // TAF Pilot Notes — forecast-oriented companion to the METAR Pilot Notes card.
            // Self-hides when there are no notes.
            tafPilotNotesSection(taf)

            // Raw TAF — separate card below the periods. Mirrors Raw METAR: always shown
            // inline when the user has enabled the section (no disclosure to fight with).
            if showRaw {
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader("Raw TAF")
                    Text(taf.rawText)
                        .font(.brandMono(11.5, weight: .medium))
                        .foregroundColor(Brand.monoDim)
                        .textSelection(.enabled)
                        .lineSpacing(2)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardBackground)
            }
        }
    }

    // MARK: - TAF hero brief
    // Plain-English 1-2 line lead: an MVFR/IFR/LIFR onset within the window leads in its
    // category color; a steady-good period reads as one quiet neutral line.
    private func tafHeroBrief(_ taf: Taf) -> Text {
        let bases = taf.baseForecasts
        guard let first = bases.first else {
            return Text("No forecast data.").foregroundColor(Brand.slate)
        }
        guard let worst = bases.max(by: { tafCategorySeverity($0.flightCategory) < tafCategorySeverity($1.flightCategory) }),
              tafCategorySeverity(worst.flightCategory) > tafCategorySeverity(first.flightCategory) else {
            // Category is steady across the period. Still surface a wind story if any period
            // gusts at or above the caution threshold (15 kt) — otherwise the hero would claim
            // "no significant changes" while the Pilot Notes card flags gusts/crosswind (amber axis).
            let firstGusty = bases.first(where: { ($0.wind?.gust ?? 0) >= 15 })
            if let gusty = firstGusty {
                return Text("\(first.flightCategory.rawValue) throughout, ")
                    .foregroundColor(Brand.cloud)
                    + Text("but gusty periods \(tafCoarseWhen(gusty.fromTime)).")
                        .foregroundColor(Brand.cautionOrange)
            }
            return Text("\(first.flightCategory.rawValue) the entire forecast period. ")
                .foregroundColor(Brand.cloud)
                + Text("No significant changes expected.").foregroundColor(Brand.slate)
        }

        let isLow = worst.flightCategory == .ifr || worst.flightCategory == .lifr
        let leadColor: Color = isLow ? Brand.valueRed : Brand.mvfrBlue
        let lead = Text("\(worst.flightCategory.rawValue) by \(tafTimeLabel(worst.fromTime)). ")
            .foregroundColor(leadColor)

        var tailParts: [String] = []
        if let c = ForecastRules.ceilingFeet(worst), c < 3000 { tailParts.append("ceiling \(c.formatted()) ft") }
        if let v = worst.visibility, v < 5 { tailParts.append("visibility \(tafVisText(v))") }
        if !worst.weatherPhenomena.isEmpty {
            tailParts.append(WeatherDecoder.decodeAll(worst.weatherPhenomena).lowercased())
        }
        let tailText: String
        if tailParts.isEmpty {
            tailText = "Watch the trend through the period."
        } else {
            let joined = tailParts.joined(separator: ", ")
            tailText = joined.prefix(1).uppercased() + joined.dropFirst() + "."
        }
        return lead + Text(tailText).foregroundColor(Brand.slate)
    }

    // Compact hero-strip time label, e.g. "5P", "8P", "11P", "12A".
    private func tafStripTimeLabel(_ date: Date) -> String {
        let hour24 = Calendar.current.component(.hour, from: date)
        let isPM = hour24 >= 12
        var hour12 = hour24 % 12
        if hour12 == 0 { hour12 = 12 }
        return "\(hour12)\(isPM ? "P" : "A")"
    }

    // "now" / "next" for the current period, else a relative-time tag ("in 3 hrs", "tomorrow").
    private func tafRelativeTag(_ period: TafForecast, isCurrent: Bool, tafIsUpcoming: Bool) -> String {
        if isCurrent { return tafIsUpcoming ? "next" : "now" }
        let hours = period.fromTime.timeIntervalSinceNow / 3600
        if hours < 0 { return "" }
        if hours < 10 { return "in \(max(1, Int(hours.rounded()))) hrs" }
        let suffix = tafDaySuffix(period.fromTime)
        return suffix.isEmpty ? "later today" : suffix.trimmingCharacters(in: .whitespaces)
    }

    // Glyph + value + time column for the TAF hero row — one per period, its limiting factor.
    private struct ForecastStripColumn: View {
        let timeLabel: String
        let factor: LimitingFactor
        var isHighlighted: Bool = false

        private var color: Color { ColorRules.flightCategoryColor(factor.category) }

        var body: some View {
            VStack(spacing: 4) {
                glyph
                valueText
                    .font(.brandMono(12.5, weight: .semibold))
                    .foregroundColor(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(timeLabel)
                    .font(.avenir(10, .medium))
                    .foregroundColor(Brand.slate)
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(minWidth: 50)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHighlighted ? Brand.accentOrange.opacity(0.08) : .clear)
            )
        }

        @ViewBuilder private var glyph: some View {
            switch factor.kind {
            case .wind:
                WindBarbGlyph(directionDeg: factor.windDirectionDeg, color: color, size: 22)
            case .ceiling:
                Image(systemName: "cloud.fill").font(.system(size: 17)).foregroundColor(color)
                    .frame(width: 22, height: 22)
            case .visibility:
                Image(systemName: "eye.fill").font(.system(size: 17)).foregroundColor(color)
                    .frame(width: 22, height: 22)
            }
        }

        @ViewBuilder private var valueText: some View {
            switch factor.kind {
            case .wind:
                if factor.windSpeedKt == 0 {
                    Text("Calm")
                } else {
                    Text(factor.windGustKt.map { "\(factor.windSpeedKt)G\($0)" } ?? "\(factor.windSpeedKt)")
                }
            case .ceiling:
                Text(factor.ceilingFeet.map { "\($0.formatted())" } ?? "CLR")
            case .visibility:
                if let v = factor.visibilitySM {
                    Text(v >= 6 ? "6+" : String(format: "%g", v))
                } else {
                    Text("—")
                }
            }
        }
    }

    // MARK: - TAF delta cards (per-period, category-keyed treatment — Decision 4)

    @ViewBuilder
    private func tafDeltaCard(_ period: TafForecast, previous: TafForecast?, tag: String) -> some View {
        switch period.flightCategory {
        case .vfr, .unknown:
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Rectangle().fill(Brand.vfrGreen.opacity(0.5)).frame(width: 3).clipShape(Capsule())
                HStack(alignment: .firstTextBaseline) {
                    HStack(spacing: 6) {
                        Text(tafLocalClock(period.fromTime)).font(.avenir(14.5, .heavy)).foregroundColor(Brand.fog)
                        if !tag.isEmpty {
                            Text(tag).font(.avenir(11.5, .demibold)).foregroundColor(Brand.monoDim)
                        }
                    }
                    Spacer()
                    Text("\(tafCompactWind(period.wind)) · \(period.flightCategory.rawValue)")
                        .font(.brandMono(12.5, weight: .semibold))
                        .foregroundColor(Brand.slate)
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 14)

        case .mvfr:
            deltaCardShell(rail: Brand.mvfrBlue,
                           wash: [Brand.mvfrBlue.opacity(0.08), Brand.mvfrBlue.opacity(0.02)],
                           border: Brand.mvfrBlue.opacity(0.3), radius: 13) {
                HStack(alignment: .firstTextBaseline) {
                    HStack(spacing: 6) {
                        Text(tafLocalClock(period.fromTime)).font(.avenir(14.5, .heavy)).foregroundColor(Brand.cloud)
                        if !tag.isEmpty {
                            Text(tag).font(.avenir(11.5, .demibold)).foregroundColor(Brand.monoDim)
                        }
                    }
                    Spacer()
                    Text("MVFR").font(.avenir(10, .heavy)).tracking(0.6).foregroundColor(Brand.mvfrBlue)
                }
                Text(tafDeltaHeadline(period, previous: previous, includePhenomena: true))
                    .font(.avenir(13.5, .bold))
                    .foregroundColor(Brand.fog)
                    .padding(.top, 3)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .ifr, .lifr:
            deltaCardShell(rail: Brand.dangerRed,
                           wash: [Brand.dangerRed.opacity(0.12), Brand.dangerRed.opacity(0.03)],
                           border: Brand.dangerRed.opacity(0.5), radius: 14, thickBorder: true) {
                HStack(alignment: .firstTextBaseline) {
                    HStack(spacing: 8) {
                        Text(tafLocalClock(period.fromTime)).font(.avenir(15.5, .heavy)).foregroundColor(Brand.cloud)
                        if !tag.isEmpty {
                            Text(tag).font(.avenir(10.5, .bold)).foregroundColor(Brand.slate)
                        }
                    }
                    Spacer()
                    StatusPill(category: period.flightCategory)
                }
                Text(tafDeltaHeadline(period, previous: previous, includePhenomena: false))
                    .font(.avenir(14.5, .bold))
                    .foregroundColor(Brand.cloud)
                    .padding(.top, 5)
                    .fixedSize(horizontal: false, vertical: true)
                let subline = tafDeltaSubline(period)
                if !subline.isEmpty {
                    Text(subline)
                        .font(.avenir(12, .demibold))
                        .foregroundColor(Brand.slate)
                        .padding(.top, 1)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func deltaCardShell<Content: View>(rail: Color, wash: [Color], border: Color, radius: CGFloat,
                                               thickBorder: Bool = false,
                                               @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle().fill(rail).frame(width: 3).clipShape(Capsule())
            VStack(alignment: .leading, spacing: 0) { content() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(LinearGradient(colors: wash, startPoint: .top, endPoint: .bottom)))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .stroke(border, lineWidth: thickBorder ? 1.5 : 1))
    }

    // "Ceiling drops to 800 ft · vis 2 SM[ · light rain]" — leads with what changed from the
    // previous period; collapses to a quiet placeholder when nothing material moved.
    private func tafDeltaHeadline(_ period: TafForecast, previous: TafForecast?, includePhenomena: Bool) -> String {
        let ceilingFt = ForecastRules.ceilingFeet(period)
        let prevCeilingFt = previous.flatMap { ForecastRules.ceilingFeet($0) }

        var parts: [String] = []
        if ceilingFt != prevCeilingFt {
            if let c = ceilingFt {
                if let prev = prevCeilingFt {
                    parts.append("Ceiling \(prev > c ? "drops to" : "lifts to") \(c.formatted()) ft")
                } else {
                    parts.append("Ceiling forms at \(c.formatted()) ft")
                }
            } else if previous != nil {
                parts.append("Ceiling clears")
            }
        }

        if period.visibility != previous?.visibility, let v = period.visibility {
            parts.append("vis \(tafVisText(v))")
        }

        if includePhenomena, !period.weatherPhenomena.isEmpty {
            parts.append(WeatherDecoder.decodeAll(period.weatherPhenomena).lowercased())
        }

        guard !parts.isEmpty else { return "— vis / sky unchanged" }
        let joined = parts.joined(separator: " · ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    // Phenomena + wind subline for the IFR/LIFR delta card (phenomena lives here, not the
    // headline, so the two never repeat the same information).
    private func tafDeltaSubline(_ period: TafForecast) -> String {
        var parts: [String] = []
        if !period.weatherPhenomena.isEmpty {
            parts.append(WeatherDecoder.decodeAll(period.weatherPhenomena))
        }
        if let wind = period.wind, wind.speed > 0 {
            parts.append("wind \(tafCompactWind(wind))")
        }
        return parts.joined(separator: " · ")
    }

    // Compact METAR-style wind token, e.g. "190° at 11G18", "CALM", "VRB at 6".
    private func tafCompactWind(_ wind: Wind?) -> String {
        guard let wind = wind else { return "—" }
        if wind.speed == 0 { return "CALM" }
        let dir = wind.isVariable ? "VRB" : String(format: "%03d°", wind.direction ?? 0)
        let gustPart = wind.gust.map { "G\($0)" } ?? ""
        return "\(dir) at \(wind.speed)\(gustPart)"
    }

    // Local "h:mm a" clock for a forecast time (Zulu → local).
    private func tafLocalClock(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        fmt.timeZone = .current
        return fmt.string(from: date)
    }

    // Day-of-week disambiguation for a forecast time relative to now's local calendar day.
    // "" = today, " tomorrow" = next local day, " MMM d" = further out (Fix 2).
    private func tafDaySuffix(_ date: Date) -> String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day],
                                      from: cal.startOfDay(for: Date()),
                                      to: cal.startOfDay(for: date)).day ?? 0
        if days <= 0 { return "" }
        if days == 1 { return " tomorrow" }
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        df.timeZone = .current
        return " \(df.string(from: date))"
    }

    // Full point-in-time label, e.g. "3:00 PM local" / "9:00 AM local tomorrow".
    private func tafTimeLabel(_ date: Date) -> String {
        "\(tafLocalClock(date)) local\(tafDaySuffix(date))"
    }

    // Window label for an overlay group, e.g. "3:00 PM–9:00 AM local tomorrow"
    // (day suffix keyed off the window start).
    private func tafWindowLabel(from: Date, to: Date) -> String {
        "\(tafLocalClock(from))–\(tafLocalClock(to)) local\(tafDaySuffix(from))"
    }

    // Coarse time-of-day phrasing for the hero wind-caution tail, e.g. "midday tomorrow",
    // "this afternoon", "tomorrow morning". Deliberately vague (Option B) — the exact gust
    // number and time live in the TAF Pilot Notes card below.
    private func tafCoarseWhen(_ date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        let partOfDay: String
        switch hour {
        case 5..<11:  partOfDay = "morning"
        case 11..<14: partOfDay = "midday"
        case 14..<18: partOfDay = "afternoon"
        case 18..<22: partOfDay = "evening"
        default:      partOfDay = "overnight"
        }
        let suffix = tafDaySuffix(date).trimmingCharacters(in: .whitespaces)
        if suffix.isEmpty {
            // Today: "this morning/afternoon/evening" reads naturally, but "this midday"
            // and "this overnight" don't — those stand alone.
            switch partOfDay {
            case "midday":    return "around midday"
            case "overnight": return "overnight"
            default:          return "this \(partOfDay)"
            }
        }
        if suffix == "tomorrow" { return "\(partOfDay) tomorrow" }
        return "\(partOfDay) \(suffix)"
    }

    // MARK: - TAF Pilot Notes
    // Forecast-oriented companion to the METAR Pilot Notes card. Every note carries timing
    // and a planning-oriented "so what". Color discipline (per design):
    //   red    = warning driven by IFR/LIFR or TS/heavy precip (category/convective meaning)
    //   orange = wind/gust warning (never red — non-IFR/non-TS)
    //   amber  = caution
    //   gray   = neutral / deteriorating-trend summary
    private struct TafPilotNote {
        let icon: String
        let text: String       // single em-dash sentence: "<timing> — <so what>" (METAR-card style)
        let color: Color
        let rank: Int          // tier: 0 red, 1 orange, 2 amber, 3 gray
        let time: Date         // forecast time, for chronological sort within a tier (Fix 2)
        var crosswind: CrosswindDisplay? = nil   // when set, renders the 3-line crosswind body
    }

    private static let tafAmber = Color(red: 1.0, green: 0.6, blue: 0.0)

    // Ceiling (lowest BKN/OVC/VV layer) in feet for a forecast period, if any.
    // Single source of truth lives in ForecastRules (WeatherStory.swift) — the TAF hero and
    // delta cards call it directly; this thin wrapper keeps the Pilot Notes call sites unchanged.
    private func tafCeilingFeet(_ period: TafForecast) -> Int? {
        ForecastRules.ceilingFeet(period)
    }

    private func tafVisText(_ vis: Double) -> String {
        vis >= 6 ? "6+ SM" : "\(String(format: "%g", vis)) SM"
    }

    // Heavy precip or thunderstorm in a period's phenomena — escalates overlay severity to warning.
    private func tafHasConvectiveOrHeavy(_ period: TafForecast) -> Bool {
        period.weatherPhenomena.contains { code in
            let c = code.uppercased()
            return c.contains("TS") || c.contains("GR") || c.hasPrefix("+") || c.contains("FC") || c.contains("FZ")
        }
        || period.clouds.contains { $0.isCumulonimbus }
    }

    private func tafCategorySeverity(_ cat: FlightCategory) -> Int {
        switch cat {
        case .vfr: return 0
        case .mvfr: return 1
        case .ifr: return 2
        case .lifr: return 3
        case .unknown: return 0
        }
    }

    private func tafPilotNotes(for taf: Taf) -> [TafPilotNote] {
        var notes: [TafPilotNote] = []
        let amber = Self.tafAmber
        let bases = taf.baseForecasts

        // 1. IFR/LIFR onset in any base/fm period — flag each transition INTO low conditions.
        for (i, p) in bases.enumerated() {
            let cat = p.flightCategory
            guard cat == .ifr || cat == .lifr else { continue }
            let prevLow = i > 0 && (bases[i - 1].flightCategory == .ifr || bases[i - 1].flightCategory == .lifr)
            if prevLow { continue }  // already in low conditions — don't repeat

            var factors: [String] = []
            if let c = tafCeilingFeet(p), c < 1000 { factors.append("ceiling \(c.formatted()) ft") }
            if let v = p.visibility, v < 3 { factors.append("visibility \(tafVisText(v))") }
            let limiting = factors.isEmpty ? "" : " (\(factors.joined(separator: ", ")))"
            notes.append(.init(
                icon: cat == .lifr ? "cloud.fog.fill" : "cloud.fill",
                text: "\(cat.rawValue) from \(tafTimeLabel(p.fromTime))\(limiting) — consider an alternate or adjust departure timing",
                color: .red, rank: 0, time: p.fromTime))
        }

        // 2. TEMPO/BECMG overlays — surfaced here, not in the period blocks.
        for p in taf.overlayForecasts {
            let label = p.type == .becmg ? "Becoming" : (p.type == .tempo ? "Temporary" : p.type.rawValue)
            let low = p.flightCategory == .ifr || p.flightCategory == .lifr
            let severe = low || tafHasConvectiveOrHeavy(p)

            var bits: [String] = []
            if let v = p.visibility { bits.append("vis \(tafVisText(v))") }
            if let c = tafCeilingFeet(p) { bits.append("ceiling \(c.formatted()) ft") }
            if !p.weatherPhenomena.isEmpty { bits.append(WeatherDecoder.decodeAll(p.weatherPhenomena).lowercased()) }
            let worst = bits.isEmpty ? p.flightCategory.rawValue : bits.joined(separator: ", ")

            notes.append(.init(
                icon: severe ? "exclamationmark.triangle.fill" : "cloud.sun.fill",
                text: "\(label) \(tafWindowLabel(from: p.fromTime, to: p.toTime)) — watch for \(worst); plan margins for this window",
                color: severe ? .red : amber,
                rank: severe ? 0 : 2, time: p.fromTime))
        }

        // 3. Gusts crossing METAR-card thresholds in any base period (caution ≥15, warning ≥20).
        for p in bases {
            guard let wind = p.wind, let gust = wind.gust, gust >= 15 else { continue }
            // Per-period crosswind range on the best runway (plus near-tie runner-up); empty → generic copy.
            let displays = crosswindDisplays(wind)
            if !displays.isEmpty {
                for (i, display) in displays.enumerated() {
                    var cw = display
                    cw.line1 = i == 0
                        ? "Gusts \(gust) kt from \(tafTimeLabel(p.fromTime)) — RWY \(cw.ident)"
                        : "or RWY \(cw.ident)"
                    // Crosswind line uses the calc wind palette (amber, red when the gust XW crosses
                    // the red threshold); ranks with the red/amber tiers so the card accent follows.
                    notes.append(.init(icon: "wind", text: cw.line1,
                                       color: cw.windColor, rank: cw.isRed ? 0 : 2,
                                       time: p.fromTime, crosswind: cw))
                }
            } else {
                let detail = gust >= 20 ? "check crosswind component for your runway" : "verify crosswind within limits"
                notes.append(.init(
                    icon: "wind",
                    text: "Gusts \(gust) kt from \(tafTimeLabel(p.fromTime)) — \(detail); \(gust >= 20 ? "add" : "consider adding") \(gust / 2) kt to approach speed",
                    color: gust >= 20 ? .orange : amber, rank: gust >= 20 ? 1 : 2, time: p.fromTime))
            }
        }

        // 4. Deteriorating trend across base periods — neutral summary.
        if bases.count >= 2 {
            let firstSev = tafCategorySeverity(bases.first!.flightCategory)
            if let worst = bases.max(by: { tafCategorySeverity($0.flightCategory) < tafCategorySeverity($1.flightCategory) }),
               tafCategorySeverity(worst.flightCategory) > firstSev,
               let onset = bases.first(where: { tafCategorySeverity($0.flightCategory) > firstSev }) {
                notes.append(.init(
                    icon: "chart.line.downtrend.xyaxis",
                    text: "Deteriorating by \(tafTimeLabel(onset.fromTime)) — forecast steps down from \(bases.first!.flightCategory.rawValue) to \(worst.flightCategory.rawValue); an earlier departure stays ahead of it",
                    color: .gray, rank: 3, time: onset.fromTime))
            }
        }

        // 5. Marginal-VFR ceiling/vis worth surfacing before it reaches IFR (optional caution).
        for p in bases where p.flightCategory == .mvfr {
            var factors: [String] = []
            if let c = tafCeilingFeet(p), c < 1500 { factors.append("ceiling \(c.formatted()) ft") }
            if let v = p.visibility, v < 4 { factors.append("visibility \(tafVisText(v))") }
            guard !factors.isEmpty else { continue }
            notes.append(.init(
                icon: "cloud",
                text: "Marginal VFR from \(tafTimeLabel(p.fromTime)) — \(factors.joined(separator: ", ")); close to IFR, watch the trend",
                color: amber, rank: 2, time: p.fromTime))
        }

        // Sort by severity tier, then chronologically within the tier (Fix 2).
        return notes.sorted { ($0.rank, $0.time) < ($1.rank, $1.time) }
    }

    private func tafPilotNotesSection(_ taf: Taf) -> some View {
        let notes = tafPilotNotes(for: taf)
        guard !notes.isEmpty else { return AnyView(EmptyView()) }

        let accent: Color = {
            if notes.contains(where: { $0.color == .red }) { return .red }
            if notes.contains(where: { $0.color == .orange }) { return .orange }
            if notes.contains(where: { $0.color == Self.tafAmber }) { return Self.tafAmber }
            return .gray
        }()

        return AnyView(
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(accent)
                        .font(.caption)
                    Text("TAF PILOT NOTES")
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
                        if let cw = note.crosswind {
                            crosswindNoteBody(cw)
                        } else {
                            Text(note.text)
                                .font(.subheadline)
                                .foregroundColor(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Text("Forecast notes only. Verify against your aircraft POH and personal minimums.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(accent.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(accent.opacity(0.25), lineWidth: 1)
                    )
            )
        )
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

        // Wind: compare gust divergence (preferred) then sustained, threshold >5kt
        let gustDiv: Int? = {
            guard let actualGust = point.actualGustKt, let forecastGust = point.forecastGustKt else { return nil }
            return actualGust - forecastGust
        }()
        let windReportDiv = gustDiv ?? windDiv  // prefer gust divergence if available
        if let wd = windReportDiv, abs(wd) > 5 {
            let stronger = wd > 0 ? "stronger" : "lighter"
            let label = gustDiv != nil ? "Gusts \(abs(wd)) kt \(stronger) than forecast" : "Wind \(abs(wd)) kt \(stronger) than forecast"
            let color: Color = abs(wd) >= 10 ? .red : Color(red: 1.0, green: 0.6, blue: 0.0)
            items.append(("wind", label, color))
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
        let windOnTarget = (windReportDiv ?? windDiv).map { abs($0) <= 5 } ?? false
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

        // Gate on ABSOLUTE density altitude via the single source of truth, matching the METAR path.
        let daSev   = daSeverity(densityAltitudeFt: Int((wx.densityAltitudeFt ?? 0).rounded()))
        let daRed   = daSev == .red
        let daAmber = daSev == .amber || daSev == .red

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

            if vm.isMetarFallback {
                HStack(spacing: 6) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Text("METAR unavailable — showing advisory estimate")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(.systemGray5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

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
            let rounded = vis >= 10 ? "10+" : "\(Int(vis.rounded()))"
            parts.append("Vis ~\(rounded) SM")
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

            // Wind — apply METAR conventions to model data:
            // direction rounded to nearest 10°, calm below 3 kt, gusts only when ≥10 kt above sustained
            let advisoryWindText: String = {
                let spd = wx.windSpeedKtRounded
                if spd < 3 { return "Calm" }
                let dir = wx.windDirectionRounded10.map { String(format: "%03d°", $0) } ?? "Variable"
                var text = "\(dir)  \(spd) kt"
                if let gust = wx.reportableGustKt {
                    text += " G\(gust) kt"
                }
                return text
            }()
            conditionRow("wind", "Wind", advisoryWindText, color: advisoryWindColor(wx))

            // Visibility — round to whole number for advisory estimates
            if let vis = wx.visibilityMiles {
                let visText = vis >= 10 ? "~10+ SM" : "~\(Int(vis.rounded())) SM"
                conditionRow("eye.fill", "Visibility",
                             visText,
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
        return .green  // calm is green
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
        let hpLoss  = max(0, daFt / 1000.0 * 3.0)   // NA power-loss estimate vs sea level, informational

        // Color/icon keyed to ABSOLUTE density altitude (single source of truth), NOT HP-loss.
        let severity = daSeverity(densityAltitudeFt: Int(daFt.rounded()))
        let daColor  = daSeverityColor(severity)
        let daIcon   = daSeverityIcon(severity)

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
                            Text(String(format: "~%.0f%% NA power loss est. · +%.0f ft above field elev", hpLoss, penalty))
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
            let hpLoss = max(0, penalty / 1000.0 * 3.0)
            if hpLoss >= 20 {
                notes.append(.init(icon: "arrow.up.to.line", text: String(format: "High density altitude ~%.0f ft — ~%.0f%% power loss, extended takeoff roll expected", da, hpLoss), isWarning: true))
            } else if hpLoss >= 10 {
                notes.append(.init(icon: "arrow.up", text: String(format: "Elevated density altitude ~%.0f ft — ~%.0f%% power loss est.; verify POH", da, hpLoss), isWarning: false))
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
                notes.append(.init(icon: "eye.slash.fill", text: "Estimated visibility ~\(Int(vis.rounded())) SM — IFR conditions possible", isWarning: true))
            } else if vis < 5 {
                notes.append(.init(icon: "eye.slash", text: "Estimated visibility ~\(Int(vis.rounded())) SM — marginal VFR", isWarning: false))
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
        let fcstWindText: String = {
            let spd = hour.windSpeedKtRounded
            if spd < 3 { return "Calm" }
            let dir = hour.windDirectionRounded10.map { String(format: "%03d°", $0) } ?? "Variable"
            var t = "\(dir)  \(spd) kt"
            if let gust = hour.reportableGustKt { t += " G\(gust) kt" }
            return t
        }()
        let visStr = hour.visibilityMiles.map { $0 >= 10 ? "~10+ SM" : "~\(Int($0.rounded())) SM" } ?? "—"

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
                    Label(fcstWindText, systemImage: "wind")
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
                    if let pHpa = hour.pressureHpa {
                        Label(String(format: "~%.2f inHg", pHpa * 0.02953), systemImage: "gauge")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                // Precip gets its own full-width row so the description reflows as whole
                // words instead of stacking one letter per line in a cramped cell.
                if hour.precipitationMm >= 0.1 {
                    Label(hour.precipDescription, systemImage: "drop.fill")
                        .font(.caption)
                        .foregroundColor(Color(red: 0.2, green: 0.5, blue: 1.0))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }

    // MARK: - Advisory Footer
    @State private var showAdvisoryInfo = false

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

            // Info button
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showAdvisoryInfo.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                    Text("About Advisory Weather")
                        .font(.caption)
                }
                .foregroundColor(.accentColor)
            }

            if showAdvisoryInfo {
                advisoryInfoPanel
            }

            if let updated = vm.lastUpdated {
                Text("Updated \(updated, style: .relative) ago")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var advisoryInfoPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What is Advisory Weather?")
                .font(.subheadline.bold())
                .foregroundColor(.primary)

            Text("Thousands of airports — especially small general aviation fields — have no ASOS, AWOS, or other automated weather station. Pilots flying to these airports traditionally have no on-field weather and must rely on stations many miles away.")
                .font(.caption)
                .foregroundColor(.secondary)

            Text("MetarMate fills this gap with Advisory Weather: estimated conditions derived from numerical weather prediction (NWP) models, provided by Open-Meteo.")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("About Open-Meteo")
                    .font(.caption.bold())
                    .foregroundColor(.primary)
                Text("Open-Meteo is a free, open-source weather API that aggregates data from national weather services worldwide, including NOAA's GFS and HRRR models and ECMWF's IFS model. It provides hourly gridded forecasts and current conditions interpolated to any location on Earth.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("How MetarMate Uses It")
                    .font(.caption.bold())
                    .foregroundColor(.primary)
                Text("For airports without official METAR reporting, MetarMate queries Open-Meteo for the airport's exact coordinates and translates model data into a familiar aviation format — estimated flight category, visibility, wind, cloud cover, temperature, dewpoint, pressure, and density altitude. Six hours of model history provide trend data, and hourly forecasts give a look-ahead.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Important Limitations")
                    .font(.caption.bold())
                    .foregroundColor(.primary)
                Text("Advisory weather is model-derived, not observed. It cannot detect local phenomena like fog forming in a valley, a sudden wind shift from terrain effects, or precipitation type changes. Visibility estimates are coarse — NWP models resolve visibility at grid scales of several kilometers. Pressure values are modeled and may differ from actual altimeter settings by ±0.2–0.3 inHg. Cloud cover is reported as a percentage, not as discrete layers with bases — ceiling estimates are inferred heuristics, not measurements.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text("Advisory weather is always visually distinguished from official METAR data with dashed borders, tilde (~) prefixes, and orange accents. It is intended for situational awareness and preflight planning — never as a substitute for official weather briefings or ATIS.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 4) {
                Image(systemName: "link")
                    .font(.system(size: 9))
                Link("open-meteo.com", destination: URL(string: "https://open-meteo.com")!)
                    .font(.caption)
            }
        }
        .padding(12)
        .background(Color(.systemGray6).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .transition(.opacity.combined(with: .move(edge: .top)))
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
        RoundedRectangle(cornerRadius: Brand.cardRadius, style: .continuous)
            .fill(Brand.cardFill)
            .overlay(
                RoundedRectangle(cornerRadius: Brand.cardRadius, style: .continuous)
                    .stroke(Brand.cardBorder, lineWidth: 1)
            )
    }

    // Brand section header — tracked caps slate + accent front-line + cold-front triangles.
    private func sectionHeader(_ title: String) -> some View {
        SectionFrontHeader(title: title)
    }

    private func windText(_ wind: Wind) -> String {
        if wind.speed == 0 { return "Calm" }
        let dir = wind.isVariable ? "Variable" : String(format: "%03d°", wind.direction ?? 0)
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
            let nextOrder = (favorites.compactMap(\.sortOrder).max() ?? -1) + 1
            let fav = AirportFavorite(from: airport, sortOrder: nextOrder)
            modelContext.insert(fav)
        }
    }
}
