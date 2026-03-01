import Foundation

// MARK: - TAF Verification
// Compares what the TAF predicted for past time periods against what was actually observed.

struct TafVerificationPoint: Identifiable, Codable {
    var id = UUID()
    var observationTime: Date
    var actualCategory: FlightCategory
    var forecastCategory: FlightCategory
    var actualCeilingFt: Int?
    var forecastCeilingFt: Int?
    var actualVisibilitySM: Double
    var forecastVisibilitySM: Double?
    var actualWindKt: Int           // sustained
    var actualGustKt: Int?
    var forecastWindKt: Int?
    var forecastGustKt: Int?

    var categoryMatch: Bool { actualCategory == forecastCategory }

    var ceilingDivergenceFt: Int? {
        guard let actual = actualCeilingFt, let forecast = forecastCeilingFt else { return nil }
        return actual - forecast
    }

    var visibilityDivergenceSM: Double? {
        guard let forecast = forecastVisibilitySM else { return nil }
        return actualVisibilitySM - forecast
    }

    var windDivergenceKt: Int? {
        guard let forecast = forecastWindKt else { return nil }
        return actualWindKt - forecast
    }

    // Shows the "show your math" actual vs forecast comparison
    var windComparisonText: String? {
        guard let fcstWind = forecastWindKt else { return nil }
        var actual = "\(actualWindKt) kt"
        if let g = actualGustKt { actual += " G\(g)" }
        var forecast = "\(fcstWind) kt"
        if let g = forecastGustKt { forecast += " G\(g)" }
        if actual == forecast { return nil }
        return "Wind: actual \(actual) · fcst \(forecast)"
    }

    var divergenceText: String {
        var parts: [String] = []

        if let ceilDiv = ceilingDivergenceFt, abs(ceilDiv) >= 300 {
            let sign = ceilDiv > 0 ? "+" : ""
            parts.append("Ceiling \(sign)\(ceilDiv.formatted()) ft vs fcst")
        } else if actualCeilingFt == nil && forecastCeilingFt != nil {
            parts.append("Ceiling cleared (fcst \(forecastCeilingFt!.formatted()) ft)")
        } else if actualCeilingFt != nil && forecastCeilingFt == nil {
            parts.append("Ceiling formed (fcst clear)")
        }

        if let visDiv = visibilityDivergenceSM, abs(visDiv) >= 0.5 {
            let sign = visDiv > 0 ? "+" : ""
            parts.append("Vis \(sign)\(String(format: "%g", visDiv)) SM vs fcst")
        }

        if let windComp = windComparisonText {
            parts.append(windComp)
        }

        if parts.isEmpty {
            return categoryMatch ? "On target" : "\(actualCategory.rawValue) vs forecast \(forecastCategory.rawValue)"
        }
        return parts.joined(separator: " · ")
    }

    var divergenceSeverity: DivergenceSeverity {
        if !categoryMatch {
            let categories: [FlightCategory] = [.vfr, .mvfr, .ifr, .lifr]
            let actualIdx = categories.firstIndex(of: actualCategory) ?? 0
            let forecastIdx = categories.firstIndex(of: forecastCategory) ?? 0
            let diff = abs(actualIdx - forecastIdx)
            return diff >= 2 ? .significant : .minor
        }
        if let ceilDiv = ceilingDivergenceFt, abs(ceilDiv) >= 800 { return .minor }
        if let visDiv = visibilityDivergenceSM, abs(visDiv) >= 1.5 { return .minor }
        if let windDiv = windDivergenceKt, abs(windDiv) >= 10 { return .minor }
        return .none
    }

    enum DivergenceSeverity {
        case none, minor, significant
    }
}

struct TafVerification: Codable {
    var points: [TafVerificationPoint]
    var categoryAccuracy: Double      // fraction of periods where flight category matched
    var windAccuracy: Double          // fraction where wind was within 10 kt of forecast
    var ceilingAccuracy: Double       // fraction where ceiling was within 500 ft of forecast
    var visibilityAccuracy: Double    // fraction where vis was within 1 SM of forecast
    var significantMisses: Int
    var summary: String

    var categoryAccuracyPct: Int { Int((categoryAccuracy * 100).rounded()) }
    var windAccuracyPct: Int { Int((windAccuracy * 100).rounded()) }
    var ceilingAccuracyPct: Int { Int((ceilingAccuracy * 100).rounded()) }
    var visibilityAccuracyPct: Int { Int((visibilityAccuracy * 100).rounded()) }

    static func derive(metars: [Metar], taf: Taf) -> TafVerification? {
        let historical = metars.count > 1 ? Array(metars.dropFirst()) : []
        guard !historical.isEmpty else { return nil }

        var points: [TafVerificationPoint] = []

        for metar in historical {
            guard let period = taf.forecasts.last(where: { $0.fromTime <= metar.observationTime }) else { continue }

            let forecastCeiling = period.clouds
                .first(where: { $0.coverage == .broken || $0.coverage == .overcast || $0.coverage == .verticalVisibility })
                .map { $0.altitude * 100 }

            let point = TafVerificationPoint(
                observationTime: metar.observationTime,
                actualCategory: metar.flightCategory,
                forecastCategory: period.flightCategory,
                actualCeilingFt: metar.ceilingFeet,
                forecastCeilingFt: forecastCeiling,
                actualVisibilitySM: metar.visibility,
                forecastVisibilitySM: period.visibility,
                actualWindKt: metar.wind.speed,
                actualGustKt: metar.wind.gust,
                forecastWindKt: period.wind?.speed,
                forecastGustKt: period.wind?.gust
            )
            points.append(point)
        }

        guard !points.isEmpty else { return nil }
        let n = Double(points.count)

        let catMatches = Double(points.filter { $0.categoryMatch }.count)

        let windClose = Double(points.filter {
            guard let div = $0.windDivergenceKt else { return true }
            return abs(div) <= 10
        }.count)

        let ceilClose = Double(points.filter {
            guard let div = $0.ceilingDivergenceFt else { return true }
            return abs(div) <= 500
        }.count)

        let visClose = Double(points.filter {
            guard let div = $0.visibilityDivergenceSM else { return true }
            return abs(div) <= 1.0
        }.count)

        let sigMisses = points.filter { $0.divergenceSeverity == .significant }.count
        let catAcc = catMatches / n

        let summary: String
        if catAcc >= 0.9 { summary = "TAF was highly accurate for the observation window." }
        else if catAcc >= 0.7 { summary = "TAF was generally accurate with some divergence." }
        else if catAcc >= 0.5 { summary = "TAF had notable divergence from actual conditions." }
        else { summary = "TAF significantly missed actual conditions. Use caution relying on forecasts." }

        return TafVerification(
            points: points,
            categoryAccuracy: catAcc,
            windAccuracy: windClose / n,
            ceilingAccuracy: ceilClose / n,
            visibilityAccuracy: visClose / n,
            significantMisses: sigMisses,
            summary: summary
        )
    }
}
