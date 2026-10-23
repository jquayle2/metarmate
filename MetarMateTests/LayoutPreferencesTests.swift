import Testing
import Foundation
@testable import MetarMate

// P3: one unknown SectionID used to fail the whole saved layout and silently reset it to defaults.
@MainActor
struct LayoutPreferencesTests {

    func store(_ json: String) -> UserDefaults {
        let ud = UserDefaults(suiteName: "LayoutPreferencesTests")!
        ud.removePersistentDomain(forName: "LayoutPreferencesTests")
        ud.set(Data(json.utf8), forKey: "metarSectionLayout")
        return ud
    }

    /// A saved layout holding a section this build doesn't know keeps the user's order and
    /// visibility; the unknown entry is dropped and missing defaults are appended.
    @Test func unknownSectionKeepsSavedLayout() {
        let ud = store(#"""
        [{"id":"taf","visibility":"Hidden"},{"id":"someFutureSection","visibility":"Always"},
         {"id":"conditions","visibility":"Always"},{"id":"trend","visibility":"Red only"}]
        """#)
        let loaded = LayoutPreferences.loadAndMigrate(keys: ["metarSectionLayout"],
                                                      defaults: LayoutPreferences.defaultMetarSections, from: ud)
        #expect(Array(loaded.prefix(3).map(\.id)) == [.taf, .conditions, .trend])
        #expect(loaded[0].visibility == .hidden)
        #expect(loaded[2].visibility == .redOnly)
        #expect(Set(loaded.map(\.id)) == Set(LayoutPreferences.defaultMetarSections.map(\.id)))
        #expect(loaded.count == LayoutPreferences.defaultMetarSections.count)
    }

    /// An unknown visibility mode drops only that entry, which comes back from the defaults.
    @Test func unknownVisibilityDropsOnlyThatEntry() {
        let ud = store(#"[{"id":"taf","visibility":"Hidden"},{"id":"trend","visibility":"Sometimes"}]"#)
        let loaded = LayoutPreferences.loadAndMigrate(keys: ["metarSectionLayout"],
                                                      defaults: LayoutPreferences.defaultMetarSections, from: ud)
        #expect(loaded.first?.id == .taf && loaded.first?.visibility == .hidden)
        #expect(loaded.first { $0.id == .trend }?.visibility == .always)
    }

    @Test func garbageFallsBackToDefaults() {
        let ud = store("not json")
        let loaded = LayoutPreferences.loadAndMigrate(keys: ["metarSectionLayout"],
                                                      defaults: LayoutPreferences.defaultMetarSections, from: ud)
        #expect(loaded.map(\.id) == LayoutPreferences.defaultMetarSections.map(\.id))
    }
}
