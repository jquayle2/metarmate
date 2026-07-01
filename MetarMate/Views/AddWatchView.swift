import SwiftUI
import SwiftData

// MARK: - AddWatchView
// The add-airport flow: search the bundled airport DB and tap one to start watching it against
// the active minimums profile. Reuses AirportService.search (same engine as the Search tab) and
// filters to METAR stations, since alerts need real observations. Creating the first watch is
// where notification authorization is requested (the gate deferred from Part A — never at
// launch, only once a watch exists).
struct AddWatchView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var existingWatches: [AirportWatch]
    @State private var searchText = ""

    private var watchedICAOs: Set<String> { Set(existingWatches.map { $0.icao }) }

    private var results: [Airport] {
        guard searchText.count >= 2 else { return [] }
        return AirportService.shared.search(query: searchText).filter { $0.hasMetar }
    }

    var body: some View {
        NavigationStack {
            Group {
                if searchText.count < 2 {
                    ContentUnavailableView("Find an Airport",
                                           systemImage: "magnifyingglass",
                                           description: Text("Search by ICAO, IATA, or name to add a watch."))
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List(results) { airport in
                        let alreadyWatched = watchedICAOs.contains(airport.icao)
                        Button { add(airport) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(airport.icao).font(.headline)
                                    Text(airport.name).font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: alreadyWatched ? "checkmark.circle.fill" : "plus.circle")
                                    .foregroundColor(alreadyWatched ? .green : .accentColor)
                            }
                        }
                        .disabled(alreadyWatched)
                    }
                    .listStyle(.plain)
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "ICAO, IATA, or airport name")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.characters)
            .navigationTitle("Add Airport")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func add(_ airport: Airport) {
        guard !watchedICAOs.contains(airport.icao) else { return }
        context.insert(AirportWatch(icao: airport.icao))
        try? context.save()
        // First-watch-creation is where we ask for notification permission (no-op if already
        // determined). The new watch is evaluated immediately by AlertsView, whose @Query
        // observes the insert and re-runs its read-only refresh.
        Task { await NotificationManager.shared.requestAuthorizationIfNeeded() }
        dismiss()
    }
}
