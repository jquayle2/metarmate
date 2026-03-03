import Foundation
import Combine

// MARK: - Section Visibility Mode
enum SectionVisibility: String, Codable, CaseIterable {
    case always         = "Always"
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
    case tafVerification  = "tafVerification"

    // Advisory sections
    case advConditions    = "advConditions"
    case advPerformance   = "advPerformance"
    case advPilotAdvisories = "advPilotAdvisories"
    case advTrends        = "advTrends"
    case advForecast      = "advForecast"

    var displayName: String {
        switch self {
        case .conditions:         return "Conditions"
        case .rawMetar:           return "Raw METAR"
        case .pilotNotes:         return "Pilot Notes"
        case .performance:        return "Performance"
        case .trend:              return "Trend"
        case .history:            return "Observation History"
        case .taf:                return "TAF"
        case .tafVerification:    return "Forecast Reliability"
        case .advConditions:      return "Conditions"
        case .advPerformance:     return "Performance"
        case .advPilotAdvisories: return "Pilot Advisories"
        case .advTrends:          return "6-Hour Trends"
        case .advForecast:        return "6-Hour Forecast"
        }
    }

    // Which visibility modes are available for this section
    var availableModes: [SectionVisibility] {
        switch self {
        case .pilotNotes, .performance, .trend, .tafVerification,
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

    private let metarKey    = "metarSectionLayout_v2"
    private let advisoryKey = "advisorySectionLayout_v2"

    // METAR section order + visibility
    @Published var metarSections: [SectionConfig] {
        didSet { save(metarSections, key: metarKey) }
    }

    // Advisory section order + visibility
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
        metarSections    = Self.load(key: "metarSectionLayout_v2")    ?? Self.defaultMetarSections
        advisorySections = Self.load(key: "advisorySectionLayout_v2") ?? Self.defaultAdvisorySections
    }

    // MARK: - Persistence
    private static func load(key: String) -> [SectionConfig]? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SectionConfig].self, from: data)
        else { return nil }
        return decoded
    }

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
    // Call these from WeatherDetailView to decide whether to render a section.

    func shouldShow(_ id: SectionID, amberCondition: Bool = false, redCondition: Bool = false) -> Bool {
        let config: SectionConfig?
        if id.rawValue.hasPrefix("adv") {
            config = advisorySections.first(where: { $0.id == id })
        } else {
            config = metarSections.first(where: { $0.id == id })
        }
        guard let c = config else { return true }
        switch c.visibility {
        case .always:        return true
        case .amberAndAbove: return amberCondition || redCondition
        case .redOnly:       return redCondition
        case .hidden:        return false
        }
    }
}
