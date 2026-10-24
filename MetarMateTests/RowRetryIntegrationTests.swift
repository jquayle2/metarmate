import Testing
import Foundation
@testable import MetarMate

// The list retry path end to end: RowWeatherLoader → WeatherService → URLSession, with a stubbed
// URLProtocol standing in for NOAA and Open-Meteo. Each test asserts the row state after every
// publish, the waits the retry policy asked for (recorded, not slept), and that no request ever went
// to Open-Meteo: a failure never triggers the estimate.
@MainActor
@Suite(.serialized)
struct RowRetryIntegrationTests {

    static let noaa = "aviationweather.gov"
    static let openMeteo = "api.open-meteo.com"

    static let kvgt = Airport(icao: "KVGT", iata: "VGT", name: "North Las Vegas",
                              latitude: 36.2107, longitude: -115.1944, elevation: 2205)
    /// A 3-char LID that reports under K-prefix (KL35): a failure must not send it to the estimate.
    static let l35 = Airport(icao: "L35", iata: nil, name: "Big Bear City",
                             latitude: 34.2638, longitude: -116.8540, elevation: 6752, hasMetar: false)

    /// A NOAA METAR JSON array for `station`, observed 10 min ago.
    static func metarJSON(_ station: String) -> Data {
        let obs = Int(Date().timeIntervalSince1970) - 600
        return Data(#"[{"icaoId":"\#(station)","obsTime":\#(obs),"rawOb":"METAR \#(station) 231551Z 20008KT 10SM CLR 19/13 A2996","temp":19,"dewp":13,"altim":1014.6,"wdir":200,"wspd":8,"visib":"10+","clouds":[],"fltCat":"VFR"}]"#.utf8)
    }

    /// Row states (by name) for `id` after each publish, the recorded retry waits, and the loader's
    /// final rows.
    func load(_ airports: [Airport], current: [String: RowWeather] = [:],
              replies: [String: [StubURLProtocol.Reply]]) async -> (states: [String: [String]], waits: [TimeInterval], final: [String: RowWeather]) {
        StubURLProtocol.reset(replies)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        let waits = WaitRecorder()
        let policy = RetryPolicy(delays: RetryPolicy.foreground.delays, sleep: { waits.record($0) })
        var states: [String: [String]] = [:]
        var final: [String: RowWeather] = [:]
        await RowWeatherLoader.load(list: "test", airports: airports, current: current, force: true,
                                    weather: WeatherService(session: session), estimates: OpenMeteoService(session: session),
                                    cache: WeatherCache(), retry: policy) { rows in
            for (id, row) in rows { states[id, default: []].append(Self.name(row)) }
            final = rows
        }
        return (states, waits.values, final)
    }

    static func name(_ row: RowWeather) -> String {
        switch row {
        case .loading: return "loading"
        case .loaded: return "loaded"
        case .noProduct: return "noProduct"
        case .retrying(let last): return last == nil ? "retrying" : "retrying(last)"
        case .failed(let last): return last == nil ? "failed" : "failed(last)"
        }
    }

    // MARK: -

    /// 429 with Retry-After, then 200: one retry after the server's 7 s (longer than the 2 s step).
    @Test func rateLimitedThenLoaded() async {
        let r = await load([Self.kvgt], replies: [Self.noaa: [.http(429, headers: ["Retry-After": "7"]),
                                                              .http(200, body: Self.metarJSON("KVGT"))]])
        #expect(r.states["KVGT"] == ["loading", "retrying", "loaded"])
        #expect(r.waits == [7])
        #expect(r.final["KVGT"]?.reading?.metar?.stationId == "KVGT")
        #expect(StubURLProtocol.requests(toHost: Self.noaa).count == 2)
        #expect(StubURLProtocol.requests(toHost: Self.openMeteo).isEmpty)
    }

    /// Timeout, timeout, then 200: retries after 2 s and 5 s.
    @Test func twoTimeoutsThenLoaded() async {
        let r = await load([Self.kvgt], replies: [Self.noaa: [.fail(.timedOut), .fail(.timedOut),
                                                              .http(200, body: Self.metarJSON("KVGT"))]])
        #expect(r.states["KVGT"] == ["loading", "retrying", "retrying", "loaded"])
        #expect(r.waits == [2, 5])
        #expect(StubURLProtocol.requests(toHost: Self.noaa).count == 3)
        #expect(StubURLProtocol.requests(toHost: Self.openMeteo).isEmpty)
    }

    /// Failures every time: the first request and the three retries (2 s, 5 s, 15 s) all fail, then
    /// the rows stop at failed. The LID L35 (KL35) fails with them and is NOT sent to the estimate.
    @Test func failuresInARowEndFailedWithoutEstimate() async {
        let r = await load([Self.kvgt, Self.l35], replies: [Self.noaa: [.http(503), .fail(.timedOut),
                                                                        .fail(.notConnectedToInternet), .http(503)]])
        #expect(r.states["KVGT"] == ["loading", "retrying", "retrying", "retrying", "retrying", "failed"])
        #expect(r.states["L35"] == ["loading", "retrying", "retrying", "retrying", "retrying", "failed"])
        #expect(r.waits == [2, 5, 15])
        #expect(StubURLProtocol.requests(toHost: Self.noaa).count == 4)   // one batch per attempt, both ids
        #expect(StubURLProtocol.requests(toHost: Self.openMeteo).isEmpty)
    }

    /// The same failures with a reading already on the row: it's kept (with its age) through the
    /// retries and the failed state, never replaced by "unavailable".
    @Test func failuresKeepTheLastGoodReading() async throws {
        let shown = try MetarParser.parse(raw: JSONDecoder().decode([RawMetar].self, from: Self.metarJSON("KVGT"))[0])
        let r = await load([Self.kvgt], current: ["KVGT": .loaded(.metar(shown))],
                           replies: [Self.noaa: [.http(503), .http(503), .http(503), .http(503)]])
        #expect(r.states["KVGT"] == ["loaded", "retrying(last)", "retrying(last)", "retrying(last)", "retrying(last)", "failed(last)"])
        #expect(r.final["KVGT"]?.reading?.metar?.stationId == "KVGT")
        #expect(StubURLProtocol.requests(toHost: Self.openMeteo).isEmpty)
    }

    /// Contrast: a confirmed no METAR (204) for the LID's K-station is what sends it to the estimate.
    @Test func noProductForTheLidSendsItToTheEstimate() async {
        let r = await load([Self.l35], replies: [Self.noaa: [.http(204)],
                                                 Self.openMeteo: [.http(200, body: Self.openMeteoJSON)]])
        #expect(r.states["L35"]?.last == "loaded")
        #expect(r.final["L35"]?.reading?.advisory != nil)
        #expect(r.waits.isEmpty)
        #expect(StubURLProtocol.requests(toHost: Self.openMeteo).count == 1)
    }

    // MARK: - Pull-to-refresh

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// A pull (force) asks NOAA even when the service cached the METAR seconds ago; an automatic
    /// load is answered by that cache.
    @Test func pullBypassesTheServiceMetarCache() async {
        StubURLProtocol.reset([Self.noaa: [.http(200, body: Self.metarJSON("KVGT")), .http(200, body: Self.metarJSON("KVGT")),
                                           .http(200, body: Self.metarJSON("KVGT"))]])
        let service = WeatherService(session: Self.session())
        _ = try? await service.metarOutcomes(for: ["KVGT"])   // the service now holds KVGT for 5 min
        for force in [false, true] {
            await RowWeatherLoader.load(list: "test", airports: [Self.kvgt], current: [:], force: force,
                                        weather: service, estimates: OpenMeteoService(session: Self.session()),
                                        cache: WeatherCache(), retry: .foreground) { _ in }
        }
        #expect(StubURLProtocol.requests(toHost: Self.noaa).count == 2)   // the priming fetch + the pull
    }

    /// A pull also re-asks a station NOAA said had no METAR (the 10-min no-product memory is for
    /// automatic loads only).
    @Test func pullBypassesTheNoProductMemory() async {
        StubURLProtocol.reset([Self.noaa: [.http(204), .http(200, body: Self.metarJSON("KVGT"))]])
        let service = WeatherService(session: Self.session())
        _ = try? await service.metarOutcomes(for: ["KVGT"])   // remembered as no product
        let auto = try? await service.metarOutcomes(for: ["KVGT"])
        let pull = try? await service.metarOutcomes(for: ["KVGT"], fresh: true)
        #expect(auto?["KVGT"]?.isNoProduct == true)
        #expect(pull?["KVGT"]?.value?.stationId == "KVGT")
        #expect(StubURLProtocol.requests(toHost: Self.noaa).count == 2)
    }

    /// A load cancelled while it retries leaves no row on "Retrying…": each goes back to what it
    /// showed before the load (a failed row stays failed with its retry button; a loaded row keeps
    /// its reading).
    @Test func cancelledLoadPutsRowsBackToWhatTheyShowed() async throws {
        let shown = try MetarParser.parse(raw: JSONDecoder().decode([RawMetar].self, from: Self.metarJSON("KLAS"))[0])
        let klas = Airport(icao: "KLAS", iata: "LAS", name: "Harry Reid", latitude: 36.08, longitude: -115.15, elevation: 2181)
        StubURLProtocol.reset([Self.noaa: [.http(503)]])
        let blocking = RetryPolicy(delays: [2, 5, 15], sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        var published: [[String: RowWeather]] = []
        let load = Task {
            await RowWeatherLoader.load(list: "test", airports: [Self.kvgt, klas],
                                        current: ["KVGT": .failed(last: nil), "KLAS": .loaded(.metar(shown))], force: true,
                                        weather: WeatherService(session: Self.session()), estimates: OpenMeteoService(session: Self.session()),
                                        cache: WeatherCache(), retry: blocking) { published.append($0) }
        }
        for _ in 0..<500 where published.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(published.last.map { Self.name($0["KVGT"]!) } == "retrying")   // mid-retry when cancelled
        load.cancel()
        await load.value
        #expect(published.last.map { Self.name($0["KVGT"]!) } == "failed")
        #expect(published.last.map { Self.name($0["KLAS"]!) } == "loaded")
        #expect(published.last?["KLAS"]?.reading?.metar?.stationId == "KLAS")
    }

    /// A minimal Open-Meteo single-location response (current + hourly blocks).
    static let openMeteoJSON = Data(#"""
    {"latitude":34.26,"longitude":-116.85,"current":{"time":1792770600,"temperature_2m":12.0,"dewpoint_2m":2.0,"relative_humidity_2m":50,"wind_speed_10m":8.0,"wind_gusts_10m":14.0,"wind_direction_10m":240,"cloud_cover":20,"precipitation":0.0,"precipitation_probability":0,"surface_pressure":810.0,"visibility":24000},"hourly":{"time":[1792767000,1792770600],"temperature_2m":[11.0,12.0],"dewpoint_2m":[2.0,2.0],"wind_speed_10m":[7.0,8.0],"wind_gusts_10m":[12.0,14.0],"wind_direction_10m":[240,240],"cloud_cover":[20,20],"precipitation":[0.0,0.0],"visibility":[24000,24000],"surface_pressure":[810.0,810.0]}}
    """#.utf8)
}

/// Records the waits RetryPolicy asks for and returns at once.
nonisolated final class WaitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []
    func record(_ wait: TimeInterval) { lock.withLock { recorded.append(wait) } }
    var values: [TimeInterval] { lock.withLock { recorded } }
}

/// Answers requests from per-host reply queues; a host with nothing queued gets HTTP 500.
nonisolated final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case http(Int, body: Data = Data(), headers: [String: String] = [:])
        case fail(URLError.Code)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var queues: [String: [Reply]] = [:]
    nonisolated(unsafe) private static var seen: [URL] = []

    static func reset(_ replies: [String: [Reply]]) { lock.withLock { queues = replies; seen = [] } }
    static func requests(toHost host: String) -> [URL] { lock.withLock { seen.filter { $0.host == host } } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let reply: Reply = Self.lock.withLock {
            Self.seen.append(url)
            let host = url.host ?? ""
            guard var queue = Self.queues[host], !queue.isEmpty else { return .http(500) }
            let next = queue.removeFirst()
            Self.queues[host] = queue
            return next
        }
        switch reply {
        case .http(let status, let body, let headers):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}
}
