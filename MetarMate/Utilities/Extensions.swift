import Foundation
import SwiftUI
import CoreLocation

// MARK: - FlightCategory SwiftUI Color
extension FlightCategory {
    // Four-way category axis (VFR green / MVFR blue / IFR red / LIFR magenta), brightened
    // for cockpit legibility. Kept self-contained (this file is shared with the Widget
    // target, which does not compile Theme.swift); values mirror Brand + ColorRules.
    nonisolated var swiftUIColor: Color {
        switch self {
        case .vfr:     return Color(red: 0.373, green: 0.773, blue: 0.533) // #5FC588
        case .mvfr:    return Color(red: 0.310, green: 0.639, blue: 0.941) // #4FA3F0
        case .ifr:     return Color(red: 1.0,   green: 0.353, blue: 0.314) // #FF5A50
        case .lifr:    return Color(red: 0.878, green: 0.416, blue: 0.816) // #E06AD0
        case .unknown: return Color(red: 0.541, green: 0.592, blue: 0.659) // #8A97A8
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
    var distanceNmString: String {
        let nm = self / 1852.0
        if nm < 10 {
            return String(format: "%.1f nm", nm)
        }
        return String(format: "%.0f nm", nm)
    }
}
