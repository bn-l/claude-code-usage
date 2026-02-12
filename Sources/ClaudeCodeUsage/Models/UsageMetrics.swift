import SwiftUI
import AppKit

struct UsageMetrics: Sendable {
    let sessionUsagePct: Double
    let weeklyUsagePct: Double
    let sessionMinsLeft: Double
    let weeklyMinsLeft: Double
    let sessionForecastPct: Double
    let weeklyBudgetBurnPct: Double
    let combinedPct: Double
    let timestamp: Date

    var colorTier: ColorTier { ColorTier(combinedPct: combinedPct) }
}

enum ColorTier: Sendable {
    case red, orange, blue, purple, green

    init(combinedPct: Double) {
        switch combinedPct {
        case ...20:  self = .red
        case ...50:  self = .orange
        case ...70:  self = .blue
        case ...90:  self = .purple
        default:     self = .green
        }
    }

    var color: Color {
        switch self {
        // case .red:    Color(red: 252 / 255, green: 165 / 255, blue: 165 / 255)
        case .red:    Color(red: 252 / 255, green: 78 / 255, blue: 78 / 255)
        case .orange: Color(red: 254 / 255, green: 215 / 255, blue: 170 / 255)
        case .blue:   Color(red: 129 / 255, green: 210 / 255, blue: 253 / 255)
        case .purple: Color(red: 196 / 255, green: 181 / 255, blue: 253 / 255)
        case .green:  Color(red: 187 / 255, green: 247 / 255, blue: 208 / 255)
        }
    }

    var cgColor: CGColor { NSColor(color).cgColor }
}
