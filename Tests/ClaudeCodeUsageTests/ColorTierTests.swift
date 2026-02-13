import Testing
import SwiftUI
import AppKit
@testable import ClaudeCodeUsage

@Suite("UsageColor — Calibrator")
struct UsageColorTests {

    @Test("Calibrator 0 (on pace) → green hue (120°)")
    func zeroIsGreen() {
        let color = UsageColor.fromCalibrator(0)
        let nsColor = NSColor(color)
        // 120/360 = 0.333
        #expect(abs(nsColor.hueComponent - 1.0 / 3.0) < 0.01)
    }

    @Test("Calibrator +1 (max headroom) → red hue (0°)")
    func plusOneIsRed() {
        let color = UsageColor.fromCalibrator(1)
        let nsColor = NSColor(color)
        #expect(nsColor.hueComponent < 0.01 || nsColor.hueComponent > 0.99)
    }

    @Test("Calibrator -1 (max overshoot) → red hue (0°)")
    func minusOneIsRed() {
        let color = UsageColor.fromCalibrator(-1)
        let nsColor = NSColor(color)
        #expect(nsColor.hueComponent < 0.01 || nsColor.hueComponent > 0.99)
    }

    @Test("Calibrator +0.5 → yellow-ish hue (~60°)")
    func halfIsYellowish() {
        let color = UsageColor.fromCalibrator(0.5)
        let nsColor = NSColor(color)
        // magnitude 0.5 → hue = 0.5 * 120/360 = 0.167
        #expect(abs(nsColor.hueComponent - 1.0 / 6.0) < 0.01)
    }

    @Test("Calibrator -0.5 → same hue as +0.5 (magnitude-based)")
    func negativeHalfSameHue() {
        let pos = NSColor(UsageColor.fromCalibrator(0.5))
        let neg = NSColor(UsageColor.fromCalibrator(-0.5))
        #expect(abs(pos.hueComponent - neg.hueComponent) < 0.01)
    }

    @Test("Values beyond [-1, 1] are clamped")
    func clamped() {
        let over = NSColor(UsageColor.fromCalibrator(2.0))
        let exact = NSColor(UsageColor.fromCalibrator(1.0))
        #expect(abs(over.hueComponent - exact.hueComponent) < 0.01)

        let under = NSColor(UsageColor.fromCalibrator(-3.0))
        let minusOne = NSColor(UsageColor.fromCalibrator(-1.0))
        #expect(abs(under.hueComponent - minusOne.hueComponent) < 0.01)
    }

    @Test("cgColorFromCalibrator round-trips through NSColor")
    func cgColorRoundtrip() {
        let color = UsageColor.fromCalibrator(0.3)
        let expected = NSColor(color).cgColor
        #expect(UsageColor.cgColorFromCalibrator(0.3) == expected)
    }
}
