import SwiftUI
import SwiftData

struct WeatherDetailView: View {
    let airport: Airport
    @StateObject private var vm = WeatherViewModel()
    @Query var favorites: [AirportFavorite]
    @Environment(\.modelContext) var modelContext
    @EnvironmentObject var airportVM: AirportViewModel

    var isFavorite: Bool { airportVM.isFavorite(airport, favorites: favorites) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if vm.isLoading {
                    ProgressView("Loading weather…")
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if let error = vm.error {
                    ContentUnavailableView(
                        "Weather Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error.localizedDescription)
                    )
                } else if let metar = vm.metar {
                    FlightCategoryBannerView(category: metar.flightCategory)
                    MetarSummaryView(metar: metar)
                    if let taf = vm.taf { TafView(taf: taf) }
                    if let trend = vm.trend { TrendView(trend: trend) }
                    RawTextView(label: "Raw METAR", text: metar.rawText)
                    if let taf = vm.taf { RawTextView(label: "Raw TAF", text: taf.rawText) }
                } else {
                    Text("No weather data available.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 60)
                }
            }
            .padding()
        }
        .navigationTitle(airport.icao)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: toggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .foregroundStyle(isFavorite ? .yellow : .primary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { Task { await vm.refresh(icao: airport.icao) } }) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(vm.isLoading)
            }
        }
        .task { await vm.load(icao: airport.icao) }
        .refreshable { await vm.refresh(icao: airport.icao) }
    }

    private func toggleFavorite() {
        if isFavorite {
            airportVM.removeFavorite(airport, favorites: favorites, context: modelContext)
        } else {
            airportVM.addFavorite(airport, context: modelContext)
        }
    }
}

// MARK: - Sub-views

struct FlightCategoryBannerView: View {
    let category: FlightCategory
    var body: some View {
        HStack {
            Text(category.rawValue)
                .font(.title2.bold())
            Text("–")
            Text(category.description)
                .font(.title3)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding()
        .background(category.swiftUIColor, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct MetarSummaryView: View {
    let metar: Metar
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Current Conditions")
                .font(.headline)
            LabeledContent("Wind", value: metar.wind.displayString)
            LabeledContent("Visibility", value: "\(metar.visibility.visibilityString) sm")
            LabeledContent("Ceiling", value: metar.ceilingFeet.map { "\($0.formatted()) ft" } ?? "Clear")
            LabeledContent("Temperature", value: "\(metar.temperature)°C / \(Int(Double(metar.temperature) * 1.8 + 32))°F")
            LabeledContent("Dewpoint", value: "\(metar.dewpoint)°C")
            LabeledContent("Altimeter", value: String(format: "%.2f inHg", metar.altimeter))
            if !metar.weatherPhenomena.isEmpty {
                LabeledContent("Weather", value: metar.weatherPhenomena.joined(separator: " "))
            }
            LabeledContent("Observed", value: metar.observationTime.relativeString)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct TafView: View {
    let taf: Taf
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Forecast (TAF)")
                .font(.headline)
            ForEach(taf.forecasts) { period in
                HStack {
                    VStack(alignment: .leading) {
                        Text(period.type.rawValue)
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text("\(period.fromTime.metarTimeString) – \(period.toTime.metarTimeString)")
                            .font(.caption)
                    }
                    Spacer()
                    Text(period.flightCategory.rawValue)
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(period.flightCategory.swiftUIColor, in: RoundedRectangle(cornerRadius: 4))
                }
                Divider()
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct TrendView: View {
    let trend: WeatherTrend
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trend")
                .font(.headline)
            HStack {
                Image(systemName: trend.overall.systemImage)
                Text(trend.summaryText)
                    .font(.subheadline)
            }
            HStack(spacing: 16) {
                TrendItemView(label: "Visibility", direction: trend.visibility)
                TrendItemView(label: "Ceiling", direction: trend.ceiling)
                TrendItemView(label: "Wind", direction: trend.wind)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct TrendItemView: View {
    let label: String
    let direction: TrendDirection
    var body: some View {
        VStack {
            Image(systemName: direction.systemImage)
                .font(.title3)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct RawTextView: View {
    let label: String
    let text: String
    @State private var isExpanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { isExpanded.toggle() }) {
                HStack {
                    Text(label)
                        .font(.headline)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
            }
            .foregroundStyle(.primary)
            if isExpanded {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
