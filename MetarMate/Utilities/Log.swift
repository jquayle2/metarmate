import Foundation
import os

// MARK: - Logging
// Centralized logging for MetarMate. Uses os.Logger so output is filterable in the
// Xcode console (and Console.app) by subsystem/category. To see only these logs in
// Xcode, type "MetarMate" in the console filter bar, or filter by one of the
// categories below (e.g. "net", "load", "asos").
//
// Categories:
//   .net   raw network fetches (URL, HTTP status, byte count, elapsed ms)
//   .load  WeatherViewModel load flow (routing, fallback decisions, totals)
//   .asos  Synoptic/ASOS boost fetches
//   .app   general app lifecycle / misc
enum Log {
    private static let subsystem = "com.jeffquayle.MetarMate"

    static let net  = Logger(subsystem: subsystem, category: "net")
    static let load = Logger(subsystem: subsystem, category: "load")
    static let asos = Logger(subsystem: subsystem, category: "asos")
    static let app  = Logger(subsystem: subsystem, category: "app")
}

// MARK: - Timing helper
// Wrap an async throwing operation, log how long it took, and re-throw any error.
// Usage:
//   let metars = try await timed("METAR history \(icao)", log: Log.net) {
//       try await weatherService.fetchMetarHistory(for: icao, hours: 6)
//   }
@discardableResult
func timed<T>(
    _ label: String,
    log: Logger = Log.app,
    _ operation: () async throws -> T
) async rethrows -> T {
    let start = DispatchTime.now()
    do {
        let result = try await operation()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        log.info("[timing] \(label, privacy: .public) - \(String(format: "%.0f", ms), privacy: .public) ms")
        return result
    } catch {
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        log.error("[timing] \(label, privacy: .public) FAILED after \(String(format: "%.0f", ms), privacy: .public) ms - \(String(describing: error), privacy: .public)")
        throw error
    }
}

// MARK: - Non-throwing timing helper
@discardableResult
func timedNonThrowing<T>(
    _ label: String,
    log: Logger = Log.app,
    _ operation: () async -> T
) async -> T {
    let start = DispatchTime.now()
    let result = await operation()
    let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    log.info("[timing] \(label, privacy: .public) - \(String(format: "%.0f", ms), privacy: .public) ms")
    return result
}
