import Foundation
import SwiftUI
import CoreLocation

// MARK: - FlightCategory SwiftUI Color
extension FlightCategory {
    nonisolated var swiftUIColor: Color {
        switch self {
        case .vfr: return .green
        case .mvfr: return .blue
        case .ifr: return .red
        case .lifr: return Color(red: 0.84, green: 0, blue: 0.98)
        case .unknown: return .gray
        }
    }
}

// MARK: - Double - Visibility / distance formatting
extension Double {
    nonisolated var visibilityString: String {
        if self >= 10 { return "10+" }
        if self == Double(Int(self)) { return "\(Int(self))" }
        return String(format: "%.1f", self)
    }

    nonisolated var metersToNauticalMiles: Double { self / 1852.0 }

    nonisolated var nmString: String {
        let nm = self.metersToNauticalMiles
        if nm < 10 { return String(format: "%.1f nm", nm) }
        return "\(Int(nm)) nm"
    }
}

// MARK: - Int - Altitude formatting
extension Int {
    nonisolated var altitudeFeetString: String { "\(self.formatted()) ft AGL" }

    nonisolated var formattedAltitude: String { self.formatted() }
}

// MARK: - Date - METAR time display
extension Date {
    nonisolated var metarTimeString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: self)
    }

    nonisolated var relativeString: String {
        let interval = Date().timeIntervalSince(self)
        if interval < 60 { return "Just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return metarTimeString
    }
}

// MARK: - Wind - Display string
extension Wind {
    nonisolated var displayString: String {
        if speed == 0 { return "Calm" }
        let dir = isVariable ? "VRB" : "\(direction ?? 0)°"
        let base = "\(dir) at \(speed)kt"
        if let g = gust { return "\(base) gusting \(g)kt" }
        return base
    }
}

// MARK: - CLLocationDistance - Nautical Miles
extension CLLocationDistance {
    var nmString: String {
        let nm = self / 1852.0
        if nm < 10 {
            return String(format: "%.1f nm", nm)
        }
        return String(format: "%.0f nm", nm)
    }
}
