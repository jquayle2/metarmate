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

    /// Pure derivation of the hero one-liner as colored segments (display order). The View
    /// concatenates the segments. Narrates from the prevailing period covering `now` onward; periods
    /// and change groups that have already ended are not part of the story.
    static func build(_ taf: Taf, now: Date = Date()) -> [HeroSegment] {
        if now >= taf.validTo {
            return [HeroSegment(text: "This TAF has expired.", color: Brand.slate)]
        }
        let bases = taf.remainingTimeline(at: now)
        guard let first = bases.first else {
            return [HeroSegment(text: "No forecast data.", color: Brand.slate)]
        }
        // If the CURRENT period's category is undetermined (an axis isn't forecast and the other
        // can't settle it), there is no honest baseline to narrate a trend from. Say so, rather than
        // dressing "unknown" up as a category ("UNKN the entire forecast period") or an improvement.
        if first.flightCategory == .unknown {
            let missing = first.unforecastAxis ?? "visibility or ceiling"
            return [HeroSegment(text: "Forecast incomplete — the current period doesn't specify \(missing).",
                                color: Brand.slate)]
        }
        let story = narrate(taf, bases: bases, first: first, now: now)
        // A current category resting on one forecast axis says which one is missing
        // ("IFR · visibility not forecast"), unless the story already did.
        if let axis = first.unforecastAxis, !story.contains(where: { $0.text.contains("not forecast") }) {
            return story + [HeroSegment(text: " Current period: \(axis) not forecast.", color: Brand.slate)]
        }
        return story
    }

    private static func narrate(_ taf: Taf, bases: [TafForecast], first: TafForecast, now: Date) -> [HeroSegment] {
        // A LATER period we couldn't determine (.unknown) must likewise never read as a worst-case
        // OR as an improvement — excluding it prevents "IFR now, improving to UNKN by 09:00."
        let known = bases.filter { $0.flightCategory != .unknown }
        let worst = known.max(by: { TafFormat.categorySeverity($0.flightCategory) < TafFormat.categorySeverity($1.flightCategory) })
        let worstBaseSeverity = worst.map { TafFormat.categorySeverity($0.flightCategory) } ?? TafFormat.categorySeverity(first.flightCategory)

        // Worst-base story: lead category/time + limiting tail — "MVFR by 09:00. Ceiling 2,500 ft."
        // Shared by the overlay path and the plain worsening branch so the tail never diverges.
        // `leading` is false when it follows an earlier hazard ("…, then MVFR by 09:00.").
        func worstBaseStory(_ w: TafForecast, leading: Bool = true) -> [HeroSegment] {
            let isLow = w.flightCategory == .ifr || w.flightCategory == .lifr
            let lead = HeroSegment(text: "\(categoryText(w, capitalized: leading)) by \(TafFormat.timeLabel(w.fromTime)). ",
                                   color: isLow ? Brand.valueRed : Brand.mvfrBlue)
            var tailParts: [String] = []
            if let c = ForecastRules.ceilingFeet(w), c < 3000 { tailParts.append("ceiling \(c.formatted()) ft") }
            if let v = w.visibility.lowerBoundSM, v < 5 { tailParts.append("visibility \(TafFormat.visText(w.visibility))") }
            if !w.weatherPhenomena.isEmpty { tailParts.append(plainWeather(w.weatherPhenomena)) }
            if let axis = w.unforecastAxis { tailParts.append("\(axis) not forecast") }
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
        // reaches overlayForecasts via the F2 fix.) Change groups that have ended don't count.
        // A BECMG whose change is under way now is possible now: it leads when it's worse than the
        // current period, rather than reading only as "<category> by <end of the window>".
        let inProgress = Set((taf.forecast(at: now)?.overlays ?? []).filter { $0.type == .becmg }.map(\.id))
        let firstSeverity = TafFormat.categorySeverity(first.flightCategory)
        if let overlay = taf.remainingOverlays(at: now).first(where: {
            TafFormat.hasConvectiveOrHeavy($0)
                || (($0.flightCategory == .ifr || $0.flightCategory == .lifr)
                    && TafFormat.categorySeverity($0.flightCategory) > worstBaseSeverity)
                || (inProgress.contains($0.id) && TafFormat.categorySeverity($0.flightCategory) > firstSeverity)
        }) {
            // Plain English: "becoming …", "temporary …"; PROB keeps its probability ("PROB30 …").
            let label = overlay.type == .becmg ? "becoming" : (overlay.type == .tempo ? "temporary" : overlay.type.rawValue)
            let low = overlay.flightCategory == .ifr || overlay.flightCategory == .lifr
            let convective = TafFormat.hasConvectiveOrHeavy(overlay)
            let what = (low || !convective)
                ? categoryText(overlay, capitalized: false)
                : (overlay.weatherPhenomena.isEmpty ? "convective activity" : plainWeather(overlay.weatherPhenomena))
            let color = low ? Brand.valueRed : (convective ? Brand.cautionOrange : Brand.mvfrBlue)
            // A BECMG's window is its change window (NOAA's toTime runs to the next change).
            let windowEnd = overlay.type == .becmg ? (overlay.becomingTime ?? overlay.toTime) : overlay.toTime
            let phrase = "\(label) \(what) \(TafFormat.windowLabel(from: overlay.fromTime, to: windowEnd))"
            let overlayClause = HeroSegment(text: " \(phrase).", color: color)
            let basesWorsen = worst.map { TafFormat.categorySeverity($0.flightCategory) > firstSeverity } ?? false
            let overlayIsWorstUnderWay = inProgress.contains(overlay.id) && worst?.id == overlay.id
            if basesWorsen, let w = worst, !overlayIsWorstUnderWay {
                // Both hazards, earliest first: "PROB30 IFR 3–6 PM, then MVFR by 9 PM. Ceiling …"
                // or "MVFR by 9 PM. Ceiling … Plus temporary thunderstorms with rain 10–11 PM."
                if overlay.fromTime < w.fromTime {
                    return [HeroSegment(text: phrase.prefix(1).uppercased() + phrase.dropFirst() + ",", color: color),
                            HeroSegment(text: " then ", color: Brand.slate)]
                        + worstBaseStory(w, leading: false)
                }
                return worstBaseStory(w) + [HeroSegment(text: " Plus", color: Brand.slate), overlayClause]
            }
            // Benign/steady base, or the worst change is already under way — contrast the current
            // category with the overlay.
            return [HeroSegment(text: "\(categoryText(first)) now,", color: ColorRules.flightCategoryColor(first.flightCategory)),
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
                return [HeroSegment(text: "\(categoryText(first)) now, ",
                                    color: ColorRules.flightCategoryColor(first.flightCategory)),
                        HeroSegment(text: "improving by \(TafFormat.timeLabel(firstBetter.fromTime)).",
                                    color: ColorRules.flightCategoryColor(firstBetter.flightCategory))]
            }
            // Category is genuinely steady across the period. Still surface a wind story if any
            // period gusts at or above the caution threshold (15 kt) — otherwise the hero would
            // claim "no significant changes" while the Pilot Notes card flags gusts (amber axis).
            let firstGusty = bases.first(where: { ($0.wind?.gust ?? 0) >= 15 })
            if let gusty = firstGusty {
                return [HeroSegment(text: "\(categoryText(first)) throughout, ", color: Brand.cloud),
                        HeroSegment(text: "but gusty periods \(TafFormat.coarseWhen(gusty.fromTime)).", color: Brand.cautionOrange)]
            }
            return [HeroSegment(text: "\(categoryText(first)) the entire forecast period. ", color: Brand.cloud),
                    HeroSegment(text: "No significant changes expected.", color: Brand.slate)]
        }

        // Bases worsen with no significant overlay — the full worst-base story (lead + limiting tail).
        return worstBaseStory(worst)
    }

    /// "IFR", or "At least IFR" when the category rests on the one axis that was forecast (the other
    /// isn't, so the true category could be worse).
    private static func categoryText(_ p: TafForecast, capitalized: Bool = true) -> String {
        guard p.unforecastAxis != nil, p.flightCategory != .unknown else { return p.flightCategory.rawValue }
        return "\(capitalized ? "At" : "at") least \(p.flightCategory.rawValue)"
    }

    /// Plain-English weather for the hero: TSRA → "thunderstorms with rain", -SHRA → "light rain
    /// showers", VCTS → "thunderstorms nearby". Intensity applies to the precipitation.
    static func plainWeather(_ codes: [String]) -> String {
        codes.map(plainWeather).joined(separator: ", ")
    }

    private static func plainWeather(_ code: String) -> String {
        var c = code.uppercased()
        var intensity = ""
        var nearby = ""
        if c.hasPrefix("+") { intensity = "heavy "; c.removeFirst() }
        else if c.hasPrefix("-") { intensity = "light "; c.removeFirst() }
        else if c.hasPrefix("VC") { nearby = " nearby"; c.removeFirst(2) }
        if c.hasPrefix("TS") {
            let rest = String(c.dropFirst(2))
            return (rest.isEmpty ? "thunderstorms" : "thunderstorms with \(intensity)\(WeatherDecoder.decode(rest).lowercased())") + nearby
        }
        if c.hasPrefix("SH") {
            let rest = String(c.dropFirst(2))
            return (rest.isEmpty ? "showers" : "\(intensity)\(WeatherDecoder.decode(rest).lowercased()) showers") + nearby
        }
        return WeatherDecoder.decode(code).lowercased()
    }
}
