import Foundation
import Combine

// MARK: - Section Visibility Mode
enum SectionVisibility: String, Codable, CaseIterable {
    case always         = "Always"
    case changingOnly   = "Changing only"
    case amberAndAbove  = "Amber or above"
    case redOnly        = "Red only"
    case hidden         = "Hidden"
}

// MARK: - Section ID
// Stable string identifiers — never change these once shipped or saved prefs break.
enum SectionID: String, Codable, CaseIterable {
    // METAR sections
    case conditions       = "conditions"
    case rawMetar         = "rawMetar"
    case pilotNotes       = "pilotNotes"
    case performance      = "performance"
    case trend            = "trend"
    case history          = "history"
    case taf              = "taf"
    case rawTaf           = "rawTaf"
    case tafVerification  = "tafVerification"

    // Advisory sections
    case advConditions      = "advConditions"
    case advPerformance     = "advPerformance"
    case advPilotAdvisories = "advPilotAdvisories"
    case advTrends          = "advTrends"
    case advForecast        = "advForecast"

    var displayName: String {
        switch self {
        case .conditions:         return "Conditions (METAR)"
        case .rawMetar:           return "Raw METAR"
        case .pilotNotes:         return "Pilot Notes"
        case .performance:        return "Performance (METAR)"
        case .trend:              return "Trend"
        case .history:            return "METAR History"
        case .taf:                return "TAF Forecast"
        case .rawTaf:             return "Raw TAF"
        case .tafVerification:    return "Forecast Reliability"
        case .advConditions:      return "Conditions"
        case .advPerformance:     return "Performance"
        case .advPilotAdvisories: return "Pilot Advisories"
        case .advTrends:          return "6-Hour Trends"
        case .advForecast:        return "6-Hour Forecast"
        }
    }

    var availableModes: [SectionVisibility] {
        switch self {
        case .trend:
            return [.always, .changingOnly, .amberAndAbove, .redOnly, .hidden]
        case .pilotNotes, .performance, .tafVerification,
             .advPerformance, .advPilotAdvisories:
            return [.always, .amberAndAbove, .redOnly, .hidden]
        default:
            return [.always, .hidden]
        }
    }
}

// MARK: - Section Config
struct SectionConfig: Codable, Identifiable {
    let id: SectionID
    var visibility: SectionVisibility
}

// MARK: - Layout Preferences
class LayoutPreferences: ObservableObject {
    static let shared = LayoutPreferences()

    // Stable keys — never bump these again. Migration handles new sections automatically.
    private let metarKey    = "metarSectionLayout"
    private let advisoryKey = "advisorySectionLayout"

    @Published var metarSections: [SectionConfig] {
        didSet { save(metarSections, key: metarKey) }
    }

    @Published var advisorySections: [SectionConfig] {
        didSet { save(advisorySections, key: advisoryKey) }
    }

    // MARK: - Defaults
    static let defaultMetarSections: [SectionConfig] = [
        .init(id: .conditions,      visibility: .always),
        .init(id: .rawMetar,        visibility: .always),
        .init(id: .pilotNotes,      visibility: .always),
        .init(id: .performance,     visibility: .always),
        .init(id: .trend,           visibility: .always),
        .init(id: .history,         visibility: .always),
        .init(id: .taf,             visibility: .always),
        .init(id: .rawTaf,          visibility: .always),
        .init(id: .tafVerification, visibility: .always),
    ]

    static let defaultAdvisorySections: [SectionConfig] = [
        .init(id: .advConditions,       visibility: .always),
        .init(id: .advPerformance,      visibility: .always),
        .init(id: .advPilotAdvisories,  visibility: .always),
        .init(id: .advTrends,           visibility: .always),
        .init(id: .advForecast,         visibility: .always),
    ]

    private init() {
        // Try stable key first, then fall back to any legacy versioned keys
        metarSections    = Self.loadAndMigrate(
            keys: ["metarSectionLayout", "metarSectionLayout_v3", "metarSectionLayout_v2", "metarSectionLayout_v1"],
            defaults: Self.defaultMetarSections
        )
        advisorySections = Self.loadAndMigrate(
            keys: ["advisorySectionLayout", "advisorySectionLayout_v3", "advisorySectionLayout_v2", "advisorySectionLayout_v1"],
            defaults: Self.defaultAdvisorySections
        )
    }

    // MARK: - Migration-aware loader
    // Tries each key in order (newest first). Takes the first valid saved data found,
    // then merges in any new sections from defaults so nothing is lost on update.
    private static func loadAndMigrate(keys: [String], defaults: [SectionConfig]) -> [SectionConfig] {
        let ud = UserDefaults.standard

        var saved: [SectionConfig]? = nil
        for key in keys {
            if let data = ud.data(forKey: key),
               let decoded = try? JSONDecoder().decode([SectionConfig].self, from: data) {
                saved = decoded
                break
            }
        }

        guard let existing = saved else { return defaults }

        // Keep saved entries whose IDs still exist in defaults (preserves order + visibility)
        let validIDs = Set(defaults.map { $0.id })
        var merged = existing.filter { validIDs.contains($0.id) }

        // Append any brand-new sections not yet in saved prefs (app update additions)
        let savedIDs = Set(merged.map { $0.id })
        let newSections = defaults.filter { !savedIDs.contains($0.id) }
        merged.append(contentsOf: newSections)

        return merged
    }

    // MARK: - Persistence
    private func save(_ sections: [SectionConfig], key: String) {
        if let data = try? JSONEncoder().encode(sections) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // MARK: - Reset
    func resetMetarToDefaults() {
        metarSections = Self.defaultMetarSections
    }

    func resetAdvisoryToDefaults() {
        advisorySections = Self.defaultAdvisorySections
    }

    // MARK: - Visibility check helpers
    func shouldShow(_ id: SectionID, amberCondition: Bool = false, redCondition: Bool = false, changingCondition: Bool = false) -> Bool {
        let config: SectionConfig?
        if id.rawValue.hasPrefix("adv") {
            config = advisorySections.first(where: { $0.id == id })
        } else {
            config = metarSections.first(where: { $0.id == id })
        }
        guard let c = config else { return true }
        switch c.visibility {
        case .always:        return true
        case .changingOnly:  return changingCondition
        case .amberAndAbove: return amberCondition || redCondition
        case .redOnly:       return redCondition
        case .hidden:        return false
        }
    }
}
