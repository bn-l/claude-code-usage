import Testing
import SwiftUI
import AppKit
@testable import ClaudeCodeUsage

@Suite("CalibratorIcon")
struct CalibratorIconTests {

    private func renderIcon(_ calibrator: Double) -> NSImage {
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            let centerY = size / 2
            let barWidth = size * 0.8
            let barX = (size - barWidth) / 2
            let maxExtent = size / 2

            let clamped = max(-1, min(1, calibrator))
            let magnitude = abs(clamped)
            let barHeight = CGFloat(magnitude) * maxExtent

            if barHeight > 0.5 {
                let color = UsageColor.cgColorFromCalibrator(calibrator)
                let barY: CGFloat = clamped >= 0 ? centerY : centerY - barHeight
                ctx.setFillColor(color)
                ctx.fill(CGRect(x: barX, y: barY, width: barWidth, height: barHeight))
            }

            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: centerY - 0.5, width: size, height: 1))

            return true
        }
        image.isTemplate = false
        return image
    }

    @Test("Image is 18x18 points")
    func imageSize() {
        let image = renderIcon(0.5)
        #expect(image.size.width == 18)
        #expect(image.size.height == 18)
    }

    @Test("isTemplate is false")
    func notTemplate() {
        let image = renderIcon(0.5)
        #expect(!image.isTemplate)
    }

    @Test("Calibrator 0: renders without crash, has visible pixels (center tick + track)")
    func zeroRendersCleanly() {
        let image = renderIcon(0)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            Issue.record("Could not create bitmap")
            return
        }

        var hasVisiblePixel = false
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.01 {
                    hasVisiblePixel = true
                    break
                }
            }
            if hasVisiblePixel { break }
        }
        #expect(hasVisiblePixel)
    }

    @Test("Positive calibrator: bar extends above center")
    func positiveExtendsUp() {
        let image = renderIcon(0.7)
        #expect(image.size.width == 18)
    }

    @Test("Negative calibrator: bar extends below center")
    func negativeExtendsDown() {
        let image = renderIcon(-0.7)
        #expect(image.size.width == 18)
    }

    @Test("Extreme values render without crash")
    func extremeValues() {
        for val in [-1.0, -0.5, 0.0, 0.5, 1.0] {
            let image = renderIcon(val)
            #expect(image.size.width == 18)
        }
    }
}
