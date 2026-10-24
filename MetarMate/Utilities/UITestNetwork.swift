import Foundation

// MARK: - UI-test network
// The simulator can't go offline on demand, so a UI test that needs "network off, then back on"
// launches the app with METARMATE_UITEST_NET set, and the two weather services' sessions answer
// from this stub instead of NOAA and Open-Meteo:
//   "online"            every request is served
//   "offline-until:T"   every request fails as offline until Unix time T, then is served (an absolute
//                       time, so the test knows exactly when the network comes back)
// Each served METAR batch has its own wind speed (batch n: 180 at 4+n kt, so the first shows 180@5),
// so a test can tell a pull that reached the network from one answered by a cache. Other NOAA products
// get 204 (no product). Every answer takes 300 ms, like the real services: an instant reply finishes a
// load before a cancel can reach it and hides cancellation bugs.
// DEBUG builds only: in Release the helpers return what they're given (verified: no stub strings in
// the Release binary).
enum UITestNetwork {
    #if DEBUG
    static let environmentKey = "METARMATE_UITEST_NET"
    #endif

    /// The session OpenMeteoService.shared uses: `fallback`, or a stubbed one under a UI test.
    nonisolated static func session(or fallback: URLSession) -> URLSession {
        #if DEBUG
        guard UITestNetworkStub.mode != nil else { return fallback }
        let config = URLSessionConfiguration.ephemeral
        install(in: config)
        return URLSession(configuration: config)
        #else
        return fallback
        #endif
    }

    /// Puts the stub in front of a session configuration under a UI test.
    nonisolated static func install(in config: URLSessionConfiguration) {
        #if DEBUG
        guard UITestNetworkStub.mode != nil else { return }
        config.protocolClasses = [UITestNetworkStub.self] + (config.protocolClasses ?? [])
        #endif
    }
}

#if DEBUG
nonisolated final class UITestNetworkStub: URLProtocol, @unchecked Sendable {
    enum Mode { case online, offline(until: Date) }

    static let mode: Mode? = {
        guard let value = ProcessInfo.processInfo.environment[UITestNetwork.environmentKey] else { return nil }
        if value.hasPrefix("offline-until:"), let t = TimeInterval(value.dropFirst("offline-until:".count)) {
            return .offline(until: Date(timeIntervalSince1970: t))
        }
        return .online
    }()

    private static let lock = NSLock()
    nonisolated(unsafe) private static var metarBatches = 0

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return host == "aviationweather.gov" || host == "api.open-meteo.com"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private var pending: DispatchWorkItem?
    override func stopLoading() { pending?.cancel() }

    override func startLoading() {
        guard let url = request.url else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if case .offline(let until)? = Self.mode, Date() < until {
                self.client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            let (status, body) = Self.reply(for: url)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        pending = item
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private static func reply(for url: URL) -> (Int, Data) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func param(_ name: String) -> String { items.first { $0.name == name }?.value ?? "" }
        if url.host == "api.open-meteo.com" {
            let count = max(1, param("latitude").split(separator: ",").count)
            let one = openMeteoLocation
            return (200, Data((count == 1 ? one : "[" + Array(repeating: one, count: count).joined(separator: ",") + "]").utf8))
        }
        guard url.path.hasSuffix("/metar") else { return (204, Data()) }
        let batch = lock.withLock { metarBatches += 1; return metarBatches }
        let speed = 4 + batch
        let obs = Int(Date().timeIntervalSince1970) - 600
        let metars = param("ids").split(separator: ",").map { id in
            #"{"icaoId":"\#(id)","obsTime":\#(obs),"rawOb":"METAR \#(id) 241551Z 180\#(String(format: "%02d", speed))KT 10SM CLR 19/13 A2996","temp":19,"dewp":13,"altim":1014.6,"wdir":180,"wspd":\#(speed),"visib":"10+","clouds":[],"fltCat":"VFR"}"#
        }
        return (200, Data(("[" + metars.joined(separator: ",") + "]").utf8))
    }

    private static let openMeteoLocation = #"{"latitude":36.2,"longitude":-115.2,"current":{"time":1792770600,"temperature_2m":12.0,"dewpoint_2m":2.0,"relative_humidity_2m":50,"wind_speed_10m":8.0,"wind_gusts_10m":14.0,"wind_direction_10m":240,"cloud_cover":20,"precipitation":0.0,"precipitation_probability":0,"surface_pressure":810.0,"visibility":24000},"hourly":{"time":[1792767000,1792770600],"temperature_2m":[11.0,12.0],"dewpoint_2m":[2.0,2.0],"wind_speed_10m":[7.0,8.0],"wind_gusts_10m":[12.0,14.0],"wind_direction_10m":[240,240],"cloud_cover":[20,20],"precipitation":[0.0,0.0],"visibility":[24000,24000],"surface_pressure":[810.0,810.0]}}"#
}
#endif
