import Foundation

/// World Magnetic Model (WMM2025) magnetic declination, computed from latitude/longitude.
///
/// Why this exists: METAR/TAF/winds-aloft are referenced to TRUE north, but runway numbers
/// — and therefore the crosswind frame pilots and ForeFlight reason in — are MAGNETIC. To
/// match them, the true METAR wind must be rotated into the magnetic frame using the local
/// declination. Declination varies by location, so it is computed from the airport's lat/lon
/// (not a fixed national offset).
///
/// Coefficients are the authoritative NOAA WMM2025 set (valid 2025.0–2030.0), embedded
/// verbatim. Declination sign convention is EAST POSITIVE. Output validated to within ~0.3°
/// of NOAA's published values at KVGT (+11.5), KSEA (+15.5), and KBOS (−14).
@MainActor
final class MagneticDeclination {
    static let shared = MagneticDeclination()

    private let nmax = 12
    private let epoch = 2025.0
    private let refRadius = 6371.2          // geomagnetic reference radius (km)
    private let aWGS = 6378.137             // WGS84 semi-major axis (km)
    private let bWGS = 6356.7523142         // WGS84 semi-minor axis (km)

    private var g: [[Double]]               // main-field cos coefficients [n][m] (nT)
    private var h: [[Double]]               // main-field sin coefficients [n][m] (nT)
    private var dg: [[Double]]              // secular variation of g (nT/yr)
    private var dh: [[Double]]              // secular variation of h (nT/yr)
    private var schmidt: [[Double]]         // Schmidt semi-normalization factors [n][m]
    private var cache: [String: Double] = [:]

    private init() {
        let n = 12
        g = Array(repeating: Array(repeating: 0.0, count: n + 1), count: n + 1)
        h = g; dg = g; dh = g; schmidt = g

        for row in Self.coefficients.split(separator: "\n") {
            let f = row.split(separator: " ")
            guard f.count == 6, let nn = Int(f[0]), let mm = Int(f[1]) else { continue }
            g[nn][mm]  = Double(f[2]) ?? 0
            h[nn][mm]  = Double(f[3]) ?? 0
            dg[nn][mm] = Double(f[4]) ?? 0
            dh[nn][mm] = Double(f[5]) ?? 0
        }

        // Schmidt semi-normalization factors, applied to the Gauss-normalized Legendre
        // functions so they pair with the Schmidt-normalized WMM coefficients.
        schmidt[0][0] = 1.0
        for nn in 1...n {
            schmidt[nn][0] = schmidt[nn - 1][0] * Double(2 * nn - 1) / Double(nn)
            for mm in 1...nn {
                let delta = (mm == 1) ? 2.0 : 1.0
                schmidt[nn][mm] = schmidt[nn][mm - 1]
                    * (Double(nn - mm + 1) * delta / Double(nn + mm)).squareRoot()
            }
        }
    }

    /// East-positive magnetic declination (degrees) at the coordinate for `date`.
    func declination(latitude: Double, longitude: Double, date: Date = Date()) -> Double {
        let key = "\(Int((latitude * 100).rounded())),\(Int((longitude * 100).rounded()))"
        if let cached = cache[key] { return cached }

        // WMM2025 is valid 2025.0–2030.0; clamp so out-of-range dates don't extrapolate wildly.
        let dt = min(2030.0, max(2025.0, decimalYear(date))) - epoch

        let rlat = latitude * .pi / 180
        let rlon = longitude * .pi / 180
        let srlat = sin(rlat), crlat = cos(rlat)

        // Geodetic → geocentric spherical (radius r, colatitude theta), at sea level (alt 0).
        let a2 = aWGS * aWGS, b2 = bWGS * bWGS
        let nradius = aWGS / (1 - (1 - b2 / a2) * srlat * srlat).squareRoot()
        let p = nradius * crlat
        let z = nradius * b2 / a2 * srlat
        let r = (p * p + z * z).squareRoot()
        let theta = atan2(p, z)
        let st = sin(theta), ct = cos(theta)

        // Gauss-normalized associated Legendre functions and their theta-derivatives.
        var P = Array(repeating: Array(repeating: 0.0, count: nmax + 1), count: nmax + 1)
        var dP = P
        P[0][0] = 1.0
        for nn in 1...nmax {
            for mm in 0...nn {
                if nn == mm {
                    P[nn][mm] = st * P[nn - 1][mm - 1]
                    dP[nn][mm] = st * dP[nn - 1][mm - 1] + ct * P[nn - 1][mm - 1]
                } else {
                    var k = 0.0
                    if nn > 1 {
                        k = Double((nn - 1) * (nn - 1) - mm * mm)
                            / Double((2 * nn - 1) * (2 * nn - 3))
                    }
                    let pn2 = (mm <= nn - 2) ? P[nn - 2][mm] : 0.0
                    let dpn2 = (mm <= nn - 2) ? dP[nn - 2][mm] : 0.0
                    P[nn][mm] = ct * P[nn - 1][mm] - k * pn2
                    dP[nn][mm] = ct * dP[nn - 1][mm] - st * P[nn - 1][mm] - k * dpn2
                }
            }
        }

        // Spherical-harmonic synthesis → geocentric north (Xp), east (Yp), down (Zp).
        var xp = 0.0, yp = 0.0, zp = 0.0
        let aor = refRadius / r
        for nn in 1...nmax {
            let f = pow(aor, Double(nn + 2))
            for mm in 0...nn {
                let gnm = g[nn][mm] + dt * dg[nn][mm]
                let hnm = h[nn][mm] + dt * dh[nn][mm]
                let cosm = cos(Double(mm) * rlon), sinm = sin(Double(mm) * rlon)
                let s = schmidt[nn][mm]
                let pnm = s * P[nn][mm], dpnm = s * dP[nn][mm]
                xp += f * (gnm * cosm + hnm * sinm) * dpnm
                yp += f * Double(mm) * (gnm * sinm - hnm * cosm) * pnm / st
                zp -= Double(nn + 1) * f * (gnm * cosm + hnm * sinm) * pnm
            }
        }

        // Rotate geocentric north/down into the geodetic frame (east is unchanged), then
        // declination is the horizontal angle east of true north.
        let psi = theta - (.pi / 2 - rlat)
        let x = xp * cos(psi) - zp * sin(psi)
        let d = atan2(yp, x) * 180 / .pi
        cache[key] = d
        return d
    }

    /// Convert a TRUE bearing (degrees) to MAGNETIC at the coordinate.
    /// magnetic = true − declination (east is least / subtract east; west is best / add west).
    func magneticFromTrue(_ trueDeg: Double, latitude: Double, longitude: Double,
                          date: Date = Date()) -> Double {
        let m = trueDeg - declination(latitude: latitude, longitude: longitude, date: date)
        return (m.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }

    private func decimalYear(_ date: Date) -> Double {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? cal.timeZone
        let year = cal.component(.year, from: date)
        guard let start = cal.date(from: DateComponents(year: year, month: 1, day: 1)),
              let next = cal.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else {
            return Double(year)
        }
        return Double(year) + date.timeIntervalSince(start) / next.timeIntervalSince(start)
    }

    /// Authoritative NOAA WMM2025 coefficients (valid 2025.0–2030.0), one row per
    /// "n m g h dg dh". Source: WMM2025.COF (NOAA NCEI, 2024-11-13).
    private static let coefficients = """
1 0 -29351.8 0.0 12.0 0.0
1 1 -1410.8 4545.4 9.7 -21.5
2 0 -2556.6 0.0 -11.6 0.0
2 1 2951.1 -3133.6 -5.2 -27.7
2 2 1649.3 -815.1 -8.0 -12.1
3 0 1361.0 0.0 -1.3 0.0
3 1 -2404.1 -56.6 -4.2 4.0
3 2 1243.8 237.5 0.4 -0.3
3 3 453.6 -549.5 -15.6 -4.1
4 0 895.0 0.0 -1.6 0.0
4 1 799.5 278.6 -2.4 -1.1
4 2 55.7 -133.9 -6.0 4.1
4 3 -281.1 212.0 5.6 1.6
4 4 12.1 -375.6 -7.0 -4.4
5 0 -233.2 0.0 0.6 0.0
5 1 368.9 45.4 1.4 -0.5
5 2 187.2 220.2 0.0 2.2
5 3 -138.7 -122.9 0.6 0.4
5 4 -142.0 43.0 2.2 1.7
5 5 20.9 106.1 0.9 1.9
6 0 64.4 0.0 -0.2 0.0
6 1 63.8 -18.4 -0.4 0.3
6 2 76.9 16.8 0.9 -1.6
6 3 -115.7 48.8 1.2 -0.4
6 4 -40.9 -59.8 -0.9 0.9
6 5 14.9 10.9 0.3 0.7
6 6 -60.7 72.7 0.9 0.9
7 0 79.5 0.0 -0.0 0.0
7 1 -77.0 -48.9 -0.1 0.6
7 2 -8.8 -14.4 -0.1 0.5
7 3 59.3 -1.0 0.5 -0.8
7 4 15.8 23.4 -0.1 0.0
7 5 2.5 -7.4 -0.8 -1.0
7 6 -11.1 -25.1 -0.8 0.6
7 7 14.2 -2.3 0.8 -0.2
8 0 23.2 0.0 -0.1 0.0
8 1 10.8 7.1 0.2 -0.2
8 2 -17.5 -12.6 0.0 0.5
8 3 2.0 11.4 0.5 -0.4
8 4 -21.7 -9.7 -0.1 0.4
8 5 16.9 12.7 0.3 -0.5
8 6 15.0 0.7 0.2 -0.6
8 7 -16.8 -5.2 -0.0 0.3
8 8 0.9 3.9 0.2 0.2
9 0 4.6 0.0 -0.0 0.0
9 1 7.8 -24.8 -0.1 -0.3
9 2 3.0 12.2 0.1 0.3
9 3 -0.2 8.3 0.3 -0.3
9 4 -2.5 -3.3 -0.3 0.3
9 5 -13.1 -5.2 0.0 0.2
9 6 2.4 7.2 0.3 -0.1
9 7 8.6 -0.6 -0.1 -0.2
9 8 -8.7 0.8 0.1 0.4
9 9 -12.9 10.0 -0.1 0.1
10 0 -1.3 0.0 0.1 0.0
10 1 -6.4 3.3 0.0 0.0
10 2 0.2 0.0 0.1 -0.0
10 3 2.0 2.4 0.1 -0.2
10 4 -1.0 5.3 -0.0 0.1
10 5 -0.6 -9.1 -0.3 -0.1
10 6 -0.9 0.4 0.0 0.1
10 7 1.5 -4.2 -0.1 0.0
10 8 0.9 -3.8 -0.1 -0.1
10 9 -2.7 0.9 -0.0 0.2
10 10 -3.9 -9.1 -0.0 -0.0
11 0 2.9 0.0 0.0 0.0
11 1 -1.5 0.0 -0.0 -0.0
11 2 -2.5 2.9 0.0 0.1
11 3 2.4 -0.6 0.0 -0.0
11 4 -0.6 0.2 0.0 0.1
11 5 -0.1 0.5 -0.1 -0.0
11 6 -0.6 -0.3 0.0 -0.0
11 7 -0.1 -1.2 -0.0 0.1
11 8 1.1 -1.7 -0.1 -0.0
11 9 -1.0 -2.9 -0.1 0.0
11 10 -0.2 -1.8 -0.1 0.0
11 11 2.6 -2.3 -0.1 0.0
12 0 -2.0 0.0 0.0 0.0
12 1 -0.2 -1.3 0.0 -0.0
12 2 0.3 0.7 -0.0 0.0
12 3 1.2 1.0 -0.0 -0.1
12 4 -1.3 -1.4 -0.0 0.1
12 5 0.6 -0.0 -0.0 -0.0
12 6 0.6 0.6 0.1 -0.0
12 7 0.5 -0.1 -0.0 -0.0
12 8 -0.1 0.8 0.0 0.0
12 9 -0.4 0.1 0.0 -0.0
12 10 -0.2 -1.0 -0.1 -0.0
12 11 -1.3 0.1 -0.0 0.0
12 12 -0.7 0.2 -0.1 -0.1
"""
}
