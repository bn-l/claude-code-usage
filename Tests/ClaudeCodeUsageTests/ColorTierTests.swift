import Testing
import SwiftUI
import AppKit
@testable import ClaudeCodeUsage

@Suite("ColorTier")
struct ColorTierTests {

    @Test("combinedPct=0 → .red", arguments: [(0.0, ColorTier.red)])
    func zeroIsRed(pct: Double, expected: ColorTier) {
        #expect(ColorTier(combinedPct: pct) == expected)
    }

    @Test("Boundary and range mapping",
          arguments: [
            (0.0,   ColorTier.red),
            (20.0,  ColorTier.red),     // ...20 includes 20
            (21.0,  ColorTier.orange),
            (50.0,  ColorTier.orange),  // boundary
            (51.0,  ColorTier.blue),
            (70.0,  ColorTier.blue),    // boundary
            (71.0,  ColorTier.purple),
            (90.0,  ColorTier.purple),  // boundary
            (91.0,  ColorTier.green),
            (100.0, ColorTier.green),
          ])
    func rangeMapping(pct: Double, expected: ColorTier) {
        #expect(ColorTier(combinedPct: pct) == expected)
    }

    @Test("Negative values fall into ...20 → .red")
    func negativeIsRed() {
        #expect(ColorTier(combinedPct: -5) == .red)
    }

    @Test("Over-100 falls into default → .green")
    func over100IsGreen() {
        #expect(ColorTier(combinedPct: 150) == .green)
    }

    @Test("cgColor is derived from color via NSColor")
    func cgColorDerived() {
        for tier in [ColorTier.red, .orange, .blue, .purple, .green] {
            let expected = NSColor(tier.color).cgColor
            #expect(tier.cgColor == expected)
        }
    }
}
