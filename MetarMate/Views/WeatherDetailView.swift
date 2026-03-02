import SwiftUI
import SwiftData
import CoreLocation

struct WeatherDetailView: View {
    let airport: Airport

    @StateObject private var vm = WeatherViewModel()
    @Query private var favorites: [AirportFavorite]
    @Environment(\.modelContext) private var modelContext

    private var isFavorite: Bool {
        favorites.contains(where: { $0.icao == airport.icao })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if vm.isLoading && vm.metar == nil {
                    ProgressView("Loading weather…")
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if vm.noWeatherReporting {
                    noReportingView
                } else if let error = vm.error, vm.metar == nil {
                    errorView(error)
                } else {
                    headerSection
                    if let metar = vm.metar {
                        rawMetarSection(metar)
                        decodedConditionsSection(metar)
                        pilotNotesSection(metar, history: vm.metarHistory)
                        densityAltitudeSection(metar)
                    }
                    if let trend = vm.trend {
                        trendSection(trend)
                    }
                    if vm.metarHistory.count > 1 {
                        metarHistorySection(vm.metarHistory)
                    }
                    if let taf = vm.taf {
                        tafSection(taf)
                    }
                    if let verification = vm.tafVerification {
                        tafVerificationSection(verification)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(airport.icao)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: toggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .foregroundColor(isFavorite ? .yellow : .secondary)
                }
            }
        }
        .task {
            await vm.load(icao: airport.icao)
        }
        .refreshable {
            await vm.refresh(icao: airport.icao)
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
            conditionRow("wind", "Wind", windText(metar.wind))
            conditionRow("eye.fill", "Visibility", visibilityText(metar.visibility))
            conditionRow("cloud.fill", "Ceiling", ceilingText(metar))
            if !metar.clouds.isEmpty {
                cloudsView(metar.clouds)
            }
            conditionRow("thermometer", "Temp / Dewpoint",
                         "\(metar.temperature)°C / \(metar.dewpoint)°C  (spread \(metar.temperature - metar.dewpoint)°)")
            conditionRow("gauge", "Altimeter", String(format: "%.2f inHg", metar.altimeter))
            if !metar.weatherPhenomena.isEmpty {
                conditionRow("cloud.bolt.rain.fill", "Weather",
                             WeatherDecoder.decodeAll(metar.weatherPhenomena))
            }
        }
        .padding()
        .background(cardBackground)
    }

    private func conditionRow(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
                .frame(width: 20)
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .foregroundColor(.primary)
            Spacer()
        }
    }

    private func cloudsView(_ layers: [CloudLayer]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "cloud.fill")
                .foregroundColor(.secondary)
                .frame(width: 20)
            Text("Clouds")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(layers.indices, id: \.self) { i in
                    let layer = layers[i]
                    let alt = (layer.altitude * 100).formatted()
                    Text("\(layer.coverage.rawValue) \(alt) ft\(layer.isCumulonimbus ? " CB" : "")")
                        .font(.subheadline)
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
        var color: Color { severity == .warning ? .orange : .yellow }
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
            notes.append(.init(icon: "wind", text: "High winds \(speed) kt — check crosswind component for your runway", severity: .warning))
        } else if speed >= 20 {
            notes.append(.init(icon: "wind", text: "Wind \(speed) kt — consider crosswind component", severity: .caution))
        }

        // Gusts
        if gust >= 15 {
            let sev: PilotNote.Severity = gust >= 20 ? .warning : .caution
            notes.append(.init(icon: "wind", text: "Gusts \(gust) kt — add \(gust / 2) kt to approach speed per rule of thumb", severity: sev))
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

        // Fog risk: temp/dewpoint spread ≤4°
        let tempDewSpread = metar.temperature - metar.dewpoint
        if tempDewSpread <= 2 {
            notes.append(.init(icon: "cloud.fog.fill", text: "Temp/dewpoint spread \(tempDewSpread)°C — fog or low stratus likely", severity: .warning))
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

        // Low altimeter (below standard = possible storm)
        if metar.altimeter < 29.70 {
            notes.append(.init(icon: "gauge.low", text: "Low altimeter \(String(format: "%.2f", metar.altimeter)) inHg — significant pressure system; check area weather", severity: .warning))
        } else if metar.altimeter < 29.90 {
            notes.append(.init(icon: "gauge", text: "Altimeter \(String(format: "%.2f", metar.altimeter)) inHg — below standard; verify altimeter setting", severity: .caution))
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
                        .foregroundColor(.orange)
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
    private func trendSection(_ trend: WeatherTrend) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Trend")

            // Alert card with background tint (Point 2)
            HStack(spacing: 10) {
                Image(systemName: trend.overall.systemImage)
                    .foregroundColor(trend.overall.color)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(trend.headline)
                        .font(.headline)
                        .foregroundColor(trend.overall.color)
                    Text(trend.summaryText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .background(trend.overall.color.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))

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
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Observation History")
            ForEach(Array(metars.enumerated()), id: \.element.id) { index, metar in
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
                if index < metars.count - 1 {
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
    private func tafSection(_ taf: Taf) -> some View {
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
            }
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

            let tafIsUpcoming = taf.validFrom > Date()
            ForEach(taf.forecasts) { period in
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

    // MARK: - TAF Verification (Forecast Reliability)
    private func tafVerificationSection(_ verification: TafVerification) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Forecast Reliability")

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(verification.categoryAccuracyPct)%")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundColor(accuracyColor(verification.categoryAccuracy))
                    Text("Category accuracy")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(verification.points.count) observations")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if verification.significantMisses > 0 {
                        Text("\(verification.significantMisses) significant miss\(verification.significantMisses == 1 ? "" : "es")")
                            .font(.caption.bold())
                            .foregroundColor(.red)
                    } else {
                        Text("No significant misses")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
            }

            // Per-parameter accuracy grid
            HStack(spacing: 16) {
                accuracyCell("Wind", verification.windAccuracyPct)
                accuracyCell("Ceiling", verification.ceilingAccuracyPct)
                accuracyCell("Visibility", verification.visibilityAccuracyPct)
            }

            Text(verification.summary)
                .font(.caption)
                .foregroundColor(.secondary)

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
        }
        .padding()
        .background(cardBackground)
    }

    private func accuracyCell(_ label: String, _ pct: Int) -> some View {
        VStack(spacing: 3) {
            Text("\(pct)%")
                .font(.subheadline.bold())
                .foregroundColor(accuracyColor(Double(pct) / 100))
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
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
                Task { await vm.load(icao: airport.icao) }
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
