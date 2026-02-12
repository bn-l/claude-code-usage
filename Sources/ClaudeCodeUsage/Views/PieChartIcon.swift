import SwiftUI
import AppKit

struct PieChartIcon: View {
    let combinedPct: Double

    var body: some View {
        Image(nsImage: renderIcon())
    }

    private func renderIcon() -> NSImage {
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size))

        image.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }

        let center = CGPoint(x: size / 2, y: size / 2)
        let radius = (size / 2) - 1

        // Pie slice from 12 o'clock, clockwise
        if combinedPct > 0 {
            let tier = ColorTier(combinedPct: combinedPct)
            let sweepAngle = CGFloat(combinedPct / 100) * 2 * .pi
            let startAngle = CGFloat.pi / 2  // 12 o'clock in CG coords
            let endAngle = startAngle - sweepAngle

            ctx.setFillColor(tier.cgColor)
            ctx.move(to: center)
            ctx.addArc(
                center: center, radius: radius,
                startAngle: startAngle, endAngle: endAngle,
                clockwise: true
            )
            ctx.closePath()
            ctx.fillPath()
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
