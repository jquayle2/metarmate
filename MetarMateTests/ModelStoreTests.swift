import Testing
import SwiftData
import Foundation
@testable import MetarMate

// Audit #23: the V1 VersionedSchema must open stores written by every earlier (unversioned) build
// without losing data, and a store that won't open must never crash the app or be moved aside
// before `moveAsideAfterFailures` failed launches in a row (Jeff, Oct 23).
@MainActor
struct ModelStoreTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func freshDefaults() -> UserDefaults {
        let name = "ModelStoreTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func writeGarbage(to url: URL) throws {
        try Data(repeating: 0xAB, count: 4096).write(to: url)
    }

    @Test func unversionedStoreOpensWithV1AndKeepsData() throws {
        let url = try tempDir().appendingPathComponent("MetarMate.store")
        // Write the store exactly as builds before #23 did: a plain, unversioned Schema.
        do {
            let legacy = Schema([AirportFavorite.self, MinimumsProfile.self, AirportWatch.self])
            let container = try ModelContainer(for: legacy, configurations: [ModelConfiguration(schema: legacy, url: url)])
            let ctx = container.mainContext
            ctx.insert(AirportFavorite(from: Airport(icao: "KVGT", iata: "VGT", name: "North Las Vegas",
                                                     latitude: 36.21, longitude: -115.19, elevation: 2205), sortOrder: 0))
            ctx.insert(MinimumsProfile(name: "My mins", isBuiltIn: false))
            ctx.insert(AirportWatch(icao: "KVGT"))
            try ctx.save()
        }

        let reopened = try ModelStore.open(at: url)
        let ctx = reopened.mainContext
        let favorites = try ctx.fetch(FetchDescriptor<AirportFavorite>())
        #expect(favorites.map(\.icao) == ["KVGT"])
        #expect(favorites.first?.name == "North Las Vegas")
        #expect(try ctx.fetch(FetchDescriptor<MinimumsProfile>()).map(\.name) == ["My mins"])
        #expect(try ctx.fetch(FetchDescriptor<AirportWatch>()).map(\.icao) == ["KVGT"])
    }

    @Test func healthyStoreOpensAndResetsFailureCount() throws {
        let url = try tempDir().appendingPathComponent("MetarMate.store")
        let defaults = freshDefaults()
        defaults.set(2, forKey: ModelStore.failureCountKey)
        let (_, outcome) = ModelStore.makeAppContainer(storeURL: url, defaults: defaults, retryDelay: 0)
        #expect(outcome == .opened)
        #expect(defaults.integer(forKey: ModelStore.failureCountKey) == 0)
    }

    @Test func unopenableStoreIsInMemoryTwiceThenMovedAsideOnTheThirdLaunch() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("MetarMate.store")
        try writeGarbage(to: url)
        let original = try Data(contentsOf: url)
        let defaults = freshDefaults()

        for launch in 1...2 {
            let (container, outcome) = ModelStore.makeAppContainer(storeURL: url, defaults: defaults, retryDelay: 0)
            #expect(outcome == .inMemory(consecutiveFailures: launch))
            // The session store works (in memory) …
            container.mainContext.insert(AirportFavorite(from: Airport(icao: "KLAS", iata: "LAS", name: "Harry Reid",
                                                                       latitude: 36.08, longitude: -115.15, elevation: 2181)))
            try container.mainContext.save()
            // … and the store on disk is untouched, still in place for the next launch.
            #expect(try Data(contentsOf: url) == original)
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(!names.contains { $0.contains(".corrupt-") })
        }

        let (container, outcome) = ModelStore.makeAppContainer(storeURL: url, defaults: defaults, retryDelay: 0)
        #expect(outcome == .movedAside)
        #expect(defaults.integer(forKey: ModelStore.failureCountKey) == 0)
        // The old file is renamed, never deleted, and byte-for-byte intact.
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let aside = try #require(names.first { $0.hasPrefix("MetarMate.store.corrupt-") && !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") })
        #expect(try Data(contentsOf: dir.appendingPathComponent(aside)) == original)
        // The fresh store is a real on-disk store at the original URL.
        #expect(try container.mainContext.fetchCount(FetchDescriptor<AirportFavorite>()) == 0)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func missingAppGroupUsesInMemoryWithoutCounting() throws {
        let defaults = freshDefaults()
        let (_, outcome) = ModelStore.makeAppContainer(storeURL: nil, defaults: defaults, retryDelay: 0)
        #expect(outcome == .inMemory(consecutiveFailures: 0))
        #expect(defaults.integer(forKey: ModelStore.failureCountKey) == 0)
    }
}
