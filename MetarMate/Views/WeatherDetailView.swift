import SwiftUI
import SwiftData

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
                } else if let error = vm.error, vm.metar == nil {
                    errorView(error)
                } else {
                    headerSection
                    if let metar = vm.metar {
                        rawMetarSection(metar)
                        decodedConditionsSection(metar)
                    }
                    if let trend = vm.trend {
                        trendSection(trend)
                    }
                    if let taf = vm.taf {
                        tafSection(taf)
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
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(cardBackground)
    }

    private func observationTimeView(_ metar: Metar) -> some View {
        let minutes = Int(Date().timeIntervalSince(metar.observationTime) / 60)
        return Text("Observed \(minutes) min ago")
            .font(.caption)
            .foregroundColor(metar.isOld ? Color(hex: "FF1744") : .secondary)
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
            conditionRow("wind.fill", "Wind", windText(metar.wind))
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
                             metar.weatherPhenomena.joined(separator: ", "))
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
                    Text("\(layer.coverage.rawValue) \(layer.altitude * 100) ft\(layer.isCumulonimbus ? " CB" : "")")
                        .font(.subheadline)
                }
            }
            Spacer()
        }
    }

    // MARK: - Trend
    private func trendSection(_ trend: WeatherTrend) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Trend")
            HStack {
                Image(systemName: trend.overall.systemImage)
                    .foregroundColor(trend.overall.color)
                    .font(.title3)
                Text("Conditions \(trend.overall.rawValue)")
                    .font(.headline)
                    .foregroundColor(trend.overall.color)
            }
            Text(trend.summaryText)
                .font(.caption)
                .foregroundColor(.secondary)
            Divider()
            TrendIndicator(direction: trend.visibility, label: "Visibility")
            TrendIndicator(direction: trend.ceiling, label: "Ceiling")
            TrendIndicator(direction: trend.wind, label: "Wind")
        }
        .padding()
        .background(cardBackground)
    }

    // MARK: - TAF
    private func tafSection(_ taf: Taf) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("TAF")
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

            ForEach(taf.forecasts) { period in
                tafPeriodRow(period, isCurrent: period.id == taf.currentForecast?.id)
            }
        }
        .padding()
        .background(cardBackground)
    }

    private func tafPeriodRow(_ period: TafForecast, isCurrent: Bool) -> some View {
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
                        Text("NOW")
                            .font(.caption2.bold())
                            .foregroundColor(.yellow)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay(Capsule().stroke(Color.yellow, lineWidth: 1))
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
                    Text("Vis: \(vis >= 10 ? "10+SM" : "\(String(format: "%g", vis))SM")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if !period.clouds.isEmpty {
                    Text(period.clouds.map { "\($0.coverage.rawValue) \($0.altitude * 100)" }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if !period.weatherPhenomena.isEmpty {
                    Text(period.weatherPhenomena.joined(separator: ", "))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .background(isCurrent ? Color.yellow.opacity(0.05) : Color.clear)
        .cornerRadius(6)
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
        guard let ceiling = metar.ceilingFeet else { return "Clear" }
        let layer = metar.clouds.first(where: { $0.coverage == .broken || $0.coverage == .overcast })
        let coverage = layer?.coverage == .overcast ? "Overcast" : "Broken"
        return "\(coverage) at \(ceiling.formatted()) ft"
    }

    private func periodTimeLabel(_ period: TafForecast) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH'Z'"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return "\(fmt.string(from: period.fromTime))–\(fmt.string(from: period.toTime))"
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
