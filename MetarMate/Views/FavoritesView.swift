import SwiftUI
import SwiftData

struct FavoritesView: View {
    @Query(sort: \AirportFavorite.addedDate, order: .forward) private var favorites: [AirportFavorite]
    @ObservedObject private var store = StoreManager.shared
    @State private var showProSheet = false

    private var sortedFavorites: [AirportFavorite] {
        let byDate = favorites.sorted { $0.addedDate < $1.addedDate }
        let dateIndex: [String: Int] = Dictionary(
            uniqueKeysWithValues: byDate.enumerated().map { ($1.icao, $0) }
        )
        return byDate.sorted {
            let a = $0.sortOrder ?? dateIndex[$0.icao] ?? 0
            let b = $1.sortOrder ?? dateIndex[$1.icao] ?? 0
            if a == b { return $0.addedDate < $1.addedDate }
            return a < b
        }
    }
    @Environment(\.modelContext) private var modelContext
    @State private var favMetars: [String: Metar] = [:]
    @State private var isLoading = false
    @State private var editMode: EditMode = .inactive

    var body: some View {
        NavigationStack {
            Group {
                if !store.isProUser {
                    proRequiredView
                } else if favorites.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "star.circle")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No Favorites Yet")
                            .font(.headline)
                        Text("Star an airport to add it here")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(sortedFavorites) { fav in
                            let airport = fav.asAirport
                            NavigationLink(destination: WeatherDetailView(airport: airport)) {
                                AirportRowView(
                                    airport: airport,
                                    metar: favMetars[airport.icao],
                                    distance: nil
                                )
                            }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 16))
                        }
                        .onDelete(perform: deleteFavorites)
                        .onMove(perform: moveFavorites)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .environment(\.editMode, $editMode)
                    .refreshable {
                        await fetchMetars()
                    }
                    .overlay {
                        if isLoading && favMetars.isEmpty {
                            ProgressView()
                        }
                    }
                }
            }
            .background(IsobarBackground())
            .navigationTitle("Favorites")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !favorites.isEmpty {
                        Button(editMode == .active ? "Done" : "Edit") {
                            withAnimation {
                                editMode = editMode == .active ? .inactive : .active
                            }
                        }
                    }
                }
            }
        }
        .task {
            await fetchMetars()
        }
        .onChange(of: favorites.map { $0.icao }) {
            Task { await fetchMetars() }
        }
    }

    private func fetchMetars() async {
        guard !favorites.isEmpty else { return }
        isLoading = true
        let icaos = favorites.filter { $0.hasMetar }.map { $0.icao }
        guard !icaos.isEmpty else { isLoading = false; return }
        if let metars = try? await WeatherService.shared.fetchMetars(for: icaos) {
            favMetars = metars
        }
        isLoading = false
    }

    private func deleteFavorites(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(sortedFavorites[index])
        }
    }

    private func moveFavorites(from source: IndexSet, to destination: Int) {
        var reordered = sortedFavorites
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, fav) in reordered.enumerated() {
            fav.sortOrder = index
        }
    }

    private var proRequiredView: some View {
        VStack(spacing: 16) {
            Image(systemName: "star.circle")
                .font(.system(size: 56))
                .foregroundColor(.yellow.opacity(0.7))
            Text("Favorites requires Pro")
                .font(.title3.bold())
            Text("Save unlimited airports for instant access with MetarMate Pro.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                showProSheet = true
            } label: {
                Text("Upgrade to Pro — $8.99")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .background(Color.cyan)
                    .cornerRadius(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showProSheet) {
            ProUpgradeView(mode: .pro)
        }
    }
}
