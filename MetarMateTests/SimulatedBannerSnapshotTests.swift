import XCTest
import SwiftUI
import SwiftData
@testable import MetarMate

// Proves the EFFECT, not the cause: the SIMULATED banner is actually painted at the top of the
// rendered pixels — on the injected WeatherDetailView AND on the pushed SimulatedRawTextScreen (the
// place \.isSimulatedWeather propagation could silently fail). Renders the real view hierarchy in a
// window (so .task/seedSimulated runs), captures the pixels, and asserts a red banner row at top.
// Also proves T4's category is TAF-sourced, not the scaffolding METAR's VFR.
@MainActor
final class SimulatedBannerSnapshotTests: XCTestCase {

    // MARK: - Banner renders on both the injected detail and the pushed sub-screen

    func testBannerRendersOnInjectedDetailAndPushedSubScreen() throws {
        let a4 = try XCTUnwrap(MetarInjectionFixtures.metars.first { $0.id == "A4" })
        let payload = SimPayload(id: a4.id, title: a4.title, airport: a4.airport, injection: try a4.make())
        let container = try ModelContainer(for: AirportFavorite.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))

        // 1) Injected detail — real WeatherDetailView, seeded, wrapped in SIMULATED chrome.
        let detail = NavigationStack { SimulatedWeatherDetailScreen(payload: payload) }
            .modelContainer(container)
        let detailImg = render(detail, settle: 1.5)
        attach(detailImg, "01-injected-detail-A4")
        XCTAssertTrue(hasRedBannerRow(detailImg, topFraction: 0.20),
                      "injected detail: no red SIMULATED banner painted at top")

        // 2) Pushed sub-screen — the propagation-critical view.
        let sub = NavigationStack { SimulatedRawTextScreen(payload: payload) }
        let subImg = render(sub, settle: 0.6)
        attach(subImg, "02-pushed-subscreen")
        XCTAssertTrue(hasRedBannerRow(subImg, topFraction: 0.20),
                      "pushed sub-screen: no red SIMULATED banner painted at top — \\.isSimulatedWeather did not propagate")

        // 3) A TAF fixture through the same path, for a second injected-detail sample (T4).
        let t4 = try XCTUnwrap(MetarInjectionFixtures.tafs.first { $0.id == "T4" })
        let t4Payload = SimPayload(id: t4.id, title: t4.title, airport: t4.airport, injection: try t4.make())
        let t4Detail = NavigationStack { SimulatedWeatherDetailScreen(payload: t4Payload) }
            .modelContainer(container)
        let t4Img = render(t4Detail, settle: 1.5)
        attach(t4Img, "03-injected-detail-T4")
        XCTAssertTrue(hasRedBannerRow(t4Img, topFraction: 0.20),
                      "T4 injected detail: no red SIMULATED banner painted at top")
    }

    // MARK: - T4 category is TAF-COMPUTED from the ceiling (structural proof)
    //
    // The scaffold now MATCHES the TAF (both IFR), so "scaffold.category != taf.category" no longer
    // proves anything. TAF-sourcing is re-derived two ways that hold even when the two agree.

    func testT4CategoryIsTafComputedFromCeiling() throws {
        let t4 = try XCTUnwrap(MetarInjectionFixtures.tafs.first { $0.id == "T4" })
        let injection = try t4.make()
        let taf = try XCTUnwrap(injection.taf)
        let scaffold = try XCTUnwrap(injection.metars.first)

        // The value UNDER TEST: the TAF period computes IFR, and it came from the CEILING — the
        // period's OWN visibility is unknown (visib ""), so vis could not have driven it.
        XCTAssertEqual(taf.forecasts.first?.flightCategory, .ifr)
        XCTAssertEqual(taf.forecasts.first?.visibility, .unknown)

        // Proof 1 — STRUCTURAL: the hero takes ONLY a Taf; it cannot read the METAR, and it reads IFR.
        let hero = TafHeroBrief.build(taf).map(\.text).joined()
        XCTAssertTrue(hero.contains("IFR"), "hero (Taf-only input) should read IFR; got: \(hero)")

        // Proof 2 — the category TRACKS THE CEILING (it is computed, not fixed): the same TAF shape
        // with the ceiling raised to 5000 ft — vis still unknown — computes VFR instead of IFR.
        let e0 = Int(Date().addingTimeInterval(-3600).timeIntervalSince1970)
        let e1 = Int(Date().addingTimeInterval(24 * 3600).timeIntervalSince1970)
        let highCeil = #"[{"icaoId":"KT04H","validTimeFrom":\#(e0),"validTimeTo":\#(e1),"rawTAF":"control 5000 ceiling","fcsts":[{"timeFrom":\#(e0),"timeTo":\#(e1),"wdir":200,"wspd":6,"visib":"","clouds":[{"cover":"BKN","base":5000}]}]}]"#
        let control = try SimulatedDecode.parseTaf(json: highCeil)
        XCTAssertEqual(control.forecasts.first?.flightCategory, .vfr,
                       "same TAF shape with a 5000 ft ceiling must compute VFR — the category is ceiling-driven, not fixed")

        // The scaffold now agrees (IFR) — which is precisely why the inequality proof is retired.
        XCTAssertEqual(scaffold.flightCategory, .ifr)
    }

    // MARK: - Scaffolds match the TAF's first period AND carry no phenomena
    //
    // Two guarantees: (1) the screen's lead chip matches the TAF (no contradicting VFR lead), and
    // (2) the scaffold injects NO weather — the category comes from vis/ceiling, so nothing bleeds
    // into the TAF case under test.

    func testScaffoldMatchesTafFirstPeriodWithNoPhenomena() throws {
        for fx in MetarInjectionFixtures.tafs {
            let inj = try fx.make()
            let scaffold = try XCTUnwrap(inj.metars.first)
            let taf = try XCTUnwrap(inj.taf)
            XCTAssertTrue(scaffold.weatherPhenomena.isEmpty,
                          "\(fx.id) scaffold METAR must carry no weather phenomena")
            XCTAssertEqual(scaffold.flightCategory, taf.forecasts.first?.flightCategory,
                           "\(fx.id) scaffold category must match the TAF's first-period category (coherent lead chip)")
        }
    }

    // MARK: - Rendering helpers

    /// Render `view` in a real key window (so SwiftUI `.task` runs), let it settle, capture pixels.
    private func render<V: View>(_ view: V, settle: TimeInterval) -> UIImage {
        let host = UIHostingController(rootView: view)
        let bounds = UIScreen.main.bounds
        let window = UIWindow(frame: bounds)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = bounds
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))   // let .task/seedSimulated apply
        host.view.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        return renderer.image { _ in host.view.drawHierarchy(in: bounds, afterScreenUpdates: true) }
    }

    private func attach(_ image: UIImage, _ name: String) {
        let att = XCTAttachment(image: image)
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }

    /// True if a row within the top `topFraction` of the image is predominantly banner-red.
    /// Banner background is Color(red: 0.80, green: 0, blue: 0) — R high, G/B low.
    private func hasRedBannerRow(_ image: UIImage, topFraction: Double) -> Bool {
        guard let cg = image.cgImage else { return false }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return false }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let maxY = min(Int(Double(h) * topFraction), h)
        for y in 0..<maxY {
            var red = 0, sampled = 0
            var x = 0
            while x < w {
                let i = (y * w + x) * 4
                let r = Double(data[i]) / 255, g = Double(data[i + 1]) / 255, b = Double(data[i + 2]) / 255
                if r > 0.5 && g < 0.25 && b < 0.25 { red += 1 }
                sampled += 1
                x += 4
            }
            if sampled > 0 && Double(red) / Double(sampled) > 0.6 { return true }
        }
        return false
    }
}
