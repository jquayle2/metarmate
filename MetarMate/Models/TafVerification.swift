import Foundation

// MARK: - TAF Verification
// Compares what the TAF predicted for past time periods against what was actually observed.
// This is the "killer feature" — pilots can see how accurate the TAF was.

struct TafVerificationPoint: Identifiable, Codable {
    var id = UUID()
    var observationTime: Date
    var actualCategory: FlightCategory
    var forecastCategory: FlightCategory
    var actualCeilingFt: Int?
    var forecastCeilingFt: Int?
    var actualVisibilitySM: Double
    var forecastVisibilitySM: Double?

    var categoryMatch: Bool { actualCategory == forecastCategory }

    var ceilingDivergenceFt: Int? {
        guard let actual = actualCeilingFt, let forecast = forecastCeilingFt else { return nil }
        return actual - forecast  // positive = actual was higher (better) than forecast
    }

    var visibilityDivergenceSM: Double? {
        guard let forecast = forecastVisibilitySM else { return nil }
        return actualVisibilitySM - forecast  // positive = actual was better than forecast
    }

    var divergenceText: String {
        var parts: [String] = []
        if let ceilDiv = ceilingDivergenceFt {
            if abs(ceilDiv) >= 300 {
                let sign = ceilDiv > 0 ? "+" : ""
                parts.append("Ceiling \(sign)\(ceilDiv.formatted()) ft vs fcst")
            }
        } else if actualCeilingFt == nil && forecastCeilingFt != nil {
            parts.append("Ceiling cleared (fcst \(forecastCeilingFt!.formatted()) ft)")
        } else if actualCeilingFt != nil && forecastCeilingFt == nil {
            parts.append("Ceiling formed (fcst clear)")
        }

        if let visDiv = visibilityDivergenceSM, abs(visDiv) >= 0.5 {
            let sign = visDiv > 0 ? "+" : ""
            parts.append("Vis \(sign)\(String(format: "%g", visDiv)) SM vs fcst")
        }

        if parts.isEmpty {
            return categoryMatch ? "On target" : "\(actualCategory.rawValue) vs forecast \(forecastCategory.rawValue)"
        }
        return parts.joined(separator: " · ")
    }

    var divergenceSeverity: DivergenceSeverity {
        if !categoryMatch {
            // Category miss — how bad?
            let categories: [FlightCategory] = [.vfr, .mvfr, .ifr, .lifr]
            let actualIdx = categories.firstIndex(of: actualCategory) ?? 0
            let forecastIdx = categories.firstIndex(of: forecastCategory) ?? 0
            let diff = abs(actualIdx - forecastIdx)
            return diff >= 2 ? .significant : .minor
        }
        if let ceilDiv = ceilingDivergenceFt, abs(ceilDiv) >= 800 { return .minor }
        if let visDiv = visibilityDivergenceSM, abs(visDiv) >= 1.5 { return .minor }
        return .none
    }

    enum DivergenceSeverity {
        case none, minor, significant

        var color: String {
            switch self {
            case .none: return "green"
            case .minor: return "yellow"
            case .significant: return "red"
            }
        }
    }
}

struct TafVerification: Codable {
    var points: [TafVerificationPoint]
    var overallAccuracy: Double        // 0-1, fraction of periods where category matched
    var significantMisses: Int
    var summary: String

    var accuracyPercent: Int { Int((overallAccuracy * 100).rounded()) }

    var accuracyText: String {
        "\(accuracyPercent)% category accuracy (\(points.count) obs)"
    }

    static func derive(metars: [Metar], taf: Taf) -> TafVerification? {
        // Only use historical METARs (skip the most recent — we want past comparisons)
        // metars are newest-first; skip index 0 (current), use the rest
        let historical = metars.count > 1 ? Array(metars.dropFirst()) : []
        guard !historical.isEmpty else { return nil }

        var points: [TafVerificationPoint] = []

        for metar in historical {
            // Find the TAF period that was valid at the time of this observation
            guard let forecastPeriod = taf.forecasts.last(where: { $0.fromTime <= metar.observationTime }) else {
                continue
            }

            let forecastCeiling = forecastPeriod.clouds
                .first(where: { $0.coverage == .broken || $0.coverage == .overcast || $0.coverage == .verticalVisibility })
                .map { $0.altitude * 100 }

            let point = TafVerificationPoint(
                observationTime: metar.observationTime,
                actualCategory: metar.flightCategory,
                forecastCategory: forecastPeriod.flightCategory,
                actualCeilingFt: metar.ceilingFeet,
                forecastCeilingFt: forecastCeiling,
                actualVisibilitySM: metar.visibility,
                forecastVisibilitySM: forecastPeriod.visibility
            )
            points.append(point)
        }

        guard !points.isEmpty else { return nil }

        let matches = points.filter { $0.categoryMatch }.count
        let accuracy = Double(matches) / Double(points.count)
        let sigMisses = points.filter { $0.divergenceSeverity == .significant }.count

        let summary: String
        if accuracy >= 0.9 {
            summary = "TAF was highly accurate for the observation window."
        } else if accuracy >= 0.7 {
            summary = "TAF was generally accurate with some divergence."
        } else if accuracy >= 0.5 {
            summary = "TAF had notable divergence from actual conditions."
        } else {
            summary = "TAF significantly missed actual conditions. Use caution relying on forecasts."
        }

        return TafVerification(
            points: points,
            overallAccuracy: accuracy,
            significantMisses: sigMisses,
            summary: summary
        )
    }
}
