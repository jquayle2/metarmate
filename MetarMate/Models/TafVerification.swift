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
    var actualVisibilitySM: Double?    // nil = the METAR didn't report visibility (omit from scoring)
    var forecastVisibilitySM: Double?
    var actualWindKt: Int?          // sustained; nil = the METAR didn't report wind (omit from scoring)
    var actualGustKt: Int?
    var forecastWindKt: Int?
    var forecastGustKt: Int?

    var categoryMatch: Bool { actualCategory == forecastCategory }

    nonisolated var ceilingDivergenceFt: Int? {
        guard let actual = actualCeilingFt, let forecast = forecastCeilingFt else { return nil }
        return actual - forecast
    }

    nonisolated var visibilityDivergenceSM: Double? {
        guard let actual = actualVisibilitySM, let forecast = forecastVisibilitySM else { return nil }
        return actual - forecast
    }

    nonisolated var windDivergenceKt: Int? {
        guard let actual = actualWindKt, let forecast = forecastWindKt else { return nil }
        return actual - forecast
    }

    // Shows the "show your math" actual vs forecast comparison
    var windComparisonText: String? {
        guard let actualWind = actualWindKt, let fcstWind = forecastWindKt else { return nil }
        var actual = "\(actualWind) kt"
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

        if let visDiv = visibilityDivergenceSM, let actual = actualVisibilitySM, let fcst = forecastVisibilitySM {
            // Only report if operationally significant (not both solidly VFR)
            let bothVFR = actual > 5.0 && fcst > 5.0
            if !bothVFR && abs(visDiv) >= 0.5 {
                let sign = visDiv > 0 ? "+" : ""
                parts.append("Vis \(sign)\(String(format: "%g", visDiv)) SM vs fcst")
            }
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
    var windAccuracy: Double?         // nil = no scoreable wind periods
    var ceilingAccuracy: Double?      // nil = no scoreable ceiling periods
    var visibilityAccuracy: Double?   // nil = no scoreable visibility periods
    var windSampleCount: Int
    var ceilingSampleCount: Int
    var visibilitySampleCount: Int
    var significantMisses: Int
    var summary: String

    nonisolated var categoryAccuracyPct: Int { Int((categoryAccuracy * 100).rounded()) }
    nonisolated var windAccuracyPct: Int? { windAccuracy.map { Int(($0 * 100).rounded()) } }
    nonisolated var ceilingAccuracyPct: Int? { ceilingAccuracy.map { Int(($0 * 100).rounded()) } }
    nonisolated var visibilityAccuracyPct: Int? { visibilityAccuracy.map { Int(($0 * 100).rounded()) } }

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
                // .exactSM: nil for .greaterThan (a >6 actual has no honest divergence magnitude —
                // omit from scoring) and .unknown; the exact value otherwise. (Finding 15 / Flag 5.)
                actualVisibilitySM: metar.visibility.exactSM,
                forecastVisibilitySM: period.visibility.exactSM,
                actualWindKt: metar.wind.isReported ? metar.wind.speed : nil,
                actualGustKt: metar.wind.isReported ? metar.wind.gust : nil,
                forecastWindKt: period.wind?.speed,
                forecastGustKt: period.wind?.gust
            )
            points.append(point)
        }

        guard !points.isEmpty else { return nil }
        let n = Double(points.count)

        let catMatches = Double(points.filter { $0.categoryMatch }.count)

        // Wind: only score periods where TAF actually specified wind; ±7kt threshold
        let windPoints = points.filter { $0.forecastWindKt != nil }
        let windClose = windPoints.isEmpty ? nil : Double(windPoints.filter {
            guard let div = $0.windDivergenceKt else { return false }
            return abs(div) <= 7
        }.count)
        let windN = Double(windPoints.count)

        // Ceiling: only score periods where at least one side had a ceiling; ±300ft threshold
        let ceilPoints = points.filter { $0.actualCeilingFt != nil || $0.forecastCeilingFt != nil }
        let ceilClose = ceilPoints.isEmpty ? nil : Double(ceilPoints.filter {
            guard let div = $0.ceilingDivergenceFt else {
                return false
            }
            return abs(div) <= 300
        }.count)
        let ceilN = Double(ceilPoints.count)

        // Visibility: only score when forecast specified vis AND conditions aren't both solidly VFR; ±0.5SM threshold
        let visPoints = points.filter {
            guard let actual = $0.actualVisibilitySM, let fcst = $0.forecastVisibilitySM else { return false }
            return !(actual > 5.0 && fcst > 5.0)
        }
        let visClose = visPoints.isEmpty ? nil : Double(visPoints.filter {
            guard let actual = $0.actualVisibilitySM, let fcst = $0.forecastVisibilitySM else { return false }
            return abs(actual - fcst) <= 0.5
        }.count)
        let visN = Double(visPoints.count)

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
            windAccuracy: windClose.map { $0 / windN },
            ceilingAccuracy: ceilClose.map { $0 / ceilN },
            visibilityAccuracy: visClose.map { $0 / visN },
            windSampleCount: windPoints.count,
            ceilingSampleCount: ceilPoints.count,
            visibilitySampleCount: visPoints.count,
            significantMisses: sigMisses,
            summary: summary
        )
    }
}
