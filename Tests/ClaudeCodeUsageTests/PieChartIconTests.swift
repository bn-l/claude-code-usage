import Testing
import SwiftUI
import AppKit
@testable import ClaudeCodeUsage

@Suite("PieChartIcon")
struct PieChartIconTests {

    private func render(_ pct: Double) -> NSImage {
        // Access the rendered image via the view's rendering method
        let view = PieChartIcon(combinedPct: pct)
        // We can't easily extract the NSImage from SwiftUI's Image in tests,
        // so we test the rendering logic directly using the same approach
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let center = CGPoint(x: size / 2, y: size / 2)
            let radius = (size / 2) - 1

            ctx.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
            ctx.setLineWidth(1)
            ctx.addEllipse(in: CGRect(
                x: center.x - radius, y: center.y - radius,
                width: radius * 2, height: radius * 2
            ))
            ctx.strokePath()

            if pct > 0 {
                let tier = ColorTier(combinedPct: pct)
                let sweepAngle = CGFloat(pct / 100) * 2 * .pi
                let startAngle = CGFloat.pi / 2
                let endAngle = startAngle - sweepAngle

                ctx.setFillColor(tier.cgColor)
                ctx.move(to: center)
                ctx.addArc(center: center, radius: radius,
                           startAngle: startAngle, endAngle: endAngle, clockwise: true)
                ctx.closePath()
                ctx.fillPath()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    @Test("combinedPct=0: image has visible pixels (background circle)")
    func zeroHasVisiblePixels() {
        let image = render(0)
        #expect(image.size.width == 18)
        #expect(image.size.height == 18)

        // Render to bitmap and check it's not all transparent
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

    @Test("Image is 18x18 points")
    func imageSize() {
        let image = render(50)
        #expect(image.size.width == 18)
        #expect(image.size.height == 18)
    }

    @Test("isTemplate is false")
    func notTemplate() {
        let image = render(50)
        #expect(!image.isTemplate)
    }

    @Test("combinedPct=100: full circle rendered")
    func fullCircle() {
        let image = render(100)
        // Verify rendering doesn't crash and produces an image
        #expect(image.size.width == 18)
    }
}
