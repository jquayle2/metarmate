import Foundation

// MARK: - TAF Forecast Period
struct TafForecast: Identifiable, Codable {
    var id = UUID()
    var type: ForecastType
    var fromTime: Date
    var toTime: Date
    var becomingTime: Date? = nil   // BECMG only: NOAA `timeBec`, when the gradual change is complete
    var wind: Wind?
    var visibility: Visibility   // .exact / .greaterThan (P6SM/P10SM) / .unknown — see Visibility
    var clouds: [CloudLayer]     // empty = sky condition not forecast (a stated clear sky is SKC/NSC)
    var weatherPhenomena: [String]
    var flightCategory: FlightCategory

    enum ForecastType: String, Codable {
        case base = "BASE"
        case fm = "FM"
        case tempo = "TEMPO"
        case becmg = "BECMG"
        case prob30 = "PROB30"
        case prob40 = "PROB40"
    }

    /// The one axis this period doesn't forecast ("visibility" / "clouds") when the other is known,
    /// for labels like "IFR · visibility not forecast". nil when both or neither are forecast.
    var unforecastAxis: String? {
        switch (visibility.isKnown, !clouds.isEmpty) {
        case (false, true): return "visibility"
        case (true, false): return "clouds"
        default:            return nil
        }
    }

    /// When this period's conditions apply. A BECMG applies once its change window ends.
    var effectiveFrom: Date { type == .becmg ? (becomingTime ?? toTime) : fromTime }
}

// MARK: - TAF
struct Taf: Identifiable, Codable {
    var id: String { stationId + issueTime.ISO8601Format() }
    var rawText: String
    var stationId: String
    var issueTime: Date
    var validFrom: Date
    var validTo: Date
    var forecasts: [TafForecast]

    var isValid: Bool {
        let now = Date()
        // Valid if active, or starts within 2 hours
        return now <= validTo && (now >= validFrom || validFrom.timeIntervalSinceNow < 7200)
    }

    // MARK: Forecast at time t
    // The single answer to "what is forecast at time t". Everything that needs the forecast for a
    // moment (current period, forecast trend, verification, hero, notes) goes through here.

    struct Conditions {
        let prevailing: TafForecast     // base/FM, or a completed BECMG — a segment of prevailingTimeline
        let overlays: [TafForecast]     // TEMPO/PROB covering t; never merged into prevailing
    }

    /// The forecast in effect at `t`, or nil outside the TAF's validity (never "current" once past
    /// `validTo`, nor before `validFrom`).
    func forecast(at t: Date) -> Conditions? {
        guard t >= validFrom, t < validTo,
              let prevailing = prevailingTimeline.last(where: { $0.fromTime <= t && t < $0.toTime })
        else { return nil }
        let overlays = forecasts.filter {
            ($0.type == .tempo || $0.type == .prob30 || $0.type == .prob40) && $0.fromTime <= t && t < $0.toTime
        }
        return Conditions(prevailing: prevailing, overlays: overlays)
    }

    /// The prevailing conditions as contiguous segments: base/FM periods, and each BECMG from the
    /// end of its change window. Each segment runs until the next one starts (the last to `validTo`).
    /// A BECMG segment keeps its period's id and carries its stated or inherited conditions.
    var prevailingTimeline: [TafForecast] {
        let starts = forecasts
            .filter { $0.type == .base || $0.type == .fm || $0.type == .becmg }
            .enumerated()
            .sorted { ($0.element.effectiveFrom, $0.offset) < ($1.element.effectiveFrom, $1.offset) }
            .map(\.element)
        var segments: [TafForecast] = []
        for (i, period) in starts.enumerated() {
            var segment = period
            segment.fromTime = period.effectiveFrom
            segment.toTime = min(i + 1 < starts.count ? starts[i + 1].effectiveFrom : validTo, validTo)
            if segment.toTime > segment.fromTime { segments.append(segment) }
        }
        return segments
    }

    /// The prevailing period now — or, for a TAF starting within 2 hours, its first period.
    var currentForecast: TafForecast? {
        currentForecast(at: Date())
    }

    func currentForecast(at now: Date) -> TafForecast? {
        if let current = forecast(at: now)?.prevailing { return current }
        if validFrom > now, validFrom.timeIntervalSince(now) < 7200 { return prevailingTimeline.first }
        return nil
    }

    /// Prevailing segments not yet over at `now` (the current one first).
    func remainingTimeline(at now: Date) -> [TafForecast] {
        prevailingTimeline.filter { $0.toTime > now }
    }

    /// TEMPO/BECMG/PROB change groups not yet over at `now`. A BECMG lasts until its prevailing
    /// segment ends, so a change that's in effect keeps its note.
    func remainingOverlays(at now: Date) -> [TafForecast] {
        let timeline = prevailingTimeline
        return overlayForecasts.filter { p in
            if p.type == .becmg {
                return (timeline.first(where: { $0.id == p.id })?.toTime ?? p.toTime) > now
            }
            return p.toTime > now
        }
    }

    // Base/FM periods only.
    var baseForecasts: [TafForecast] {
        forecasts.filter { $0.type == .base || $0.type == .fm }
    }

    // TEMPO/BECMG/PROB change groups — surfaced in TAF Pilot Notes, not in the period blocks.
    var overlayForecasts: [TafForecast] {
        forecasts.filter { $0.type == .tempo || $0.type == .becmg || $0.type == .prob30 || $0.type == .prob40 }
    }
}
