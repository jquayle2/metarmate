import SwiftUI

// MARK: - TAF hero brief (pilot-facing forecast one-liner)
// Extracted from WeatherDetailView so the (safety-critical) hero advisory text is a pure,
// unit-testable function instead of a private method returning an opaque `Text`. Each output
// segment carries its OWN color: the flight-category axis (red/blue/magenta) and the caution axis
// (amber) must never be collapsed into one — that separation is load-bearing in this app. The View
// reduces the segments back to a single `Text`. Regression: MetarMateTests.
struct HeroSegment: Equatable {
    let text: String
    let color: Color
}

enum TafHeroBrief {

    /// Pure derivation of the hero one-liner as colored segments (display order). A faithful move of
    /// the former `WeatherDetailView.tafHeroBrief` — every `Text(x).foregroundColor(c)` is now a
    /// `HeroSegment(x, c)`; strings and colors are identical. The View concatenates the segments.
    static func build(_ taf: Taf) -> [HeroSegment] {
        let bases = taf.baseForecasts
        guard let first = bases.first else {
            return [HeroSegment(text: "No forecast data.", color: Brand.slate)]
        }
        // If the CURRENT period's category is undetermined (no visibility AND no ceiling in the
        // forecast — now reachable since visibility no longer defaults to 10 SM), there is no
        // honest baseline to narrate a trend from. Say so, rather than dressing "unknown" up as a
        // category ("UNKN the entire forecast period") or an improvement.
        if first.flightCategory == .unknown {
            return [HeroSegment(text: "Forecast incomplete — the current period doesn't specify visibility or ceiling.",
                                color: Brand.slate)]
        }
        // A LATER period we couldn't determine (.unknown) must likewise never read as a worst-case
        // OR as an improvement — excluding it prevents "IFR now, improving to UNKN by 09:00."
        let known = bases.filter { $0.flightCategory != .unknown }
        let worst = known.max(by: { TafFormat.categorySeverity($0.flightCategory) < TafFormat.categorySeverity($1.flightCategory) })
        let worstBaseSeverity = worst.map { TafFormat.categorySeverity($0.flightCategory) } ?? TafFormat.categorySeverity(first.flightCategory)

        // Worst-base story: lead category/time + limiting tail — "MVFR by 09:00. Ceiling 2,500 ft."
        // Shared by the overlay path and the plain worsening branch so the tail never diverges.
        func worstBaseStory(_ w: TafForecast) -> [HeroSegment] {
            let isLow = w.flightCategory == .ifr || w.flightCategory == .lifr
            let lead = HeroSegment(text: "\(w.flightCategory.rawValue) by \(TafFormat.timeLabel(w.fromTime)). ",
                                   color: isLow ? Brand.valueRed : Brand.mvfrBlue)
            var tailParts: [String] = []
            if let c = ForecastRules.ceilingFeet(w), c < 3000 { tailParts.append("ceiling \(c.formatted()) ft") }
            if let v = w.visibility.lowerBoundSM, v < 5 { tailParts.append("visibility \(TafFormat.visText(w.visibility))") }
            if !w.weatherPhenomena.isEmpty { tailParts.append(WeatherDecoder.decodeAll(w.weatherPhenomena).lowercased()) }
            let tailText: String
            if tailParts.isEmpty {
                tailText = "Watch the trend through the period."
            } else {
                let joined = tailParts.joined(separator: ", ")
                tailText = joined.prefix(1).uppercased() + joined.dropFirst() + "."
            }
            return [lead, HeroSegment(text: tailText, color: Brand.slate)]
        }

        // A significant TEMPO/PROB overlay is a distinct hazard from the base trend and must surface
        // REGARDLESS of what the bases do — a PROB30 thunderstorm is not covered by an "MVFR by
        // 09:00" base story. Lead with it when it's convective/heavy (always), or when it is IFR/LIFR
        // AND more severe than the worst base. Hoisted above the worsening guard on purpose. (PROB
        // reaches overlayForecasts via the F2 fix.)
        if let overlay = taf.overlayForecasts.first(where: {
            TafFormat.hasConvectiveOrHeavy($0)
                || (($0.flightCategory == .ifr || $0.flightCategory == .lifr)
                    && TafFormat.categorySeverity($0.flightCategory) > worstBaseSeverity)
        }) {
            let label = overlay.type == .becmg ? "BECMG" : (overlay.type == .tempo ? "TEMPO" : overlay.type.rawValue)
            let low = overlay.flightCategory == .ifr || overlay.flightCategory == .lifr
            let what = low
                ? overlay.flightCategory.rawValue
                : (overlay.weatherPhenomena.isEmpty ? "convective activity" : WeatherDecoder.decodeAll(overlay.weatherPhenomena).lowercased())
            let overlayClause = HeroSegment(text: " \(label) \(what) \(TafFormat.windowLabel(from: overlay.fromTime, to: overlay.toTime)).",
                                            color: low ? Brand.valueRed : Brand.cautionOrange)
            let basesWorsen = worst.map { TafFormat.categorySeverity($0.flightCategory) > TafFormat.categorySeverity(first.flightCategory) } ?? false
            if basesWorsen, let w = worst {
                // Keep the full worst-base story (lead + limiting tail), then the overlay as a
                // separate sentence — both hazards, base detail intact.
                return worstBaseStory(w) + [HeroSegment(text: " Plus", color: Brand.slate), overlayClause]
            }
            // Benign/steady base — contrast the current category with the overlay hazard.
            return [HeroSegment(text: "\(first.flightCategory.rawValue) now,", color: ColorRules.flightCategoryColor(first.flightCategory)),
                    HeroSegment(text: " but", color: Brand.slate),
                    overlayClause]
        }

        // No significant overlay — the base trend logic. Nothing worse than the first period?
        guard let worst, TafFormat.categorySeverity(worst.flightCategory) > TafFormat.categorySeverity(first.flightCategory) else {
            // Nothing gets WORSE than the first period. But the forecast may still IMPROVE —
            // e.g. starts IFR and clears to VFR. Saying "IFR the entire forecast period" there
            // is wrong and would keep a pilot on the ground when the TAF says it lifts.
            if let firstBetter = known.first(where: {
                TafFormat.categorySeverity($0.flightCategory) < TafFormat.categorySeverity(first.flightCategory)
            }) {
                // CFII ruling (Mike): drop the destination-category suffix — say "improving" without
                // naming the better category (a TAF improvement is not a guarantee to plan against).
                // The segment color still carries the improved category; only the words change.
                return [HeroSegment(text: "\(first.flightCategory.rawValue) now, ",
                                    color: ColorRules.flightCategoryColor(first.flightCategory)),
                        HeroSegment(text: "improving by \(TafFormat.timeLabel(firstBetter.fromTime)).",
                                    color: ColorRules.flightCategoryColor(firstBetter.flightCategory))]
            }
            // Category is genuinely steady across the period. Still surface a wind story if any
            // period gusts at or above the caution threshold (15 kt) — otherwise the hero would
            // claim "no significant changes" while the Pilot Notes card flags gusts (amber axis).
            let firstGusty = bases.first(where: { ($0.wind?.gust ?? 0) >= 15 })
            if let gusty = firstGusty {
                return [HeroSegment(text: "\(first.flightCategory.rawValue) throughout, ", color: Brand.cloud),
                        HeroSegment(text: "but gusty periods \(TafFormat.coarseWhen(gusty.fromTime)).", color: Brand.cautionOrange)]
            }
            return [HeroSegment(text: "\(first.flightCategory.rawValue) the entire forecast period. ", color: Brand.cloud),
                    HeroSegment(text: "No significant changes expected.", color: Brand.slate)]
        }

        // Bases worsen with no significant overlay — the full worst-base story (lead + limiting tail).
        return worstBaseStory(worst)
    }
}
