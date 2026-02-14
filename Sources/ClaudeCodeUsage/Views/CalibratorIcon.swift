import SwiftUI
import AppKit
import OSLog

private let logger = Logger(subsystem: "com.bml.claude-code-usage", category: "CalibratorIcon")

struct CalibratorIcon: View {
    let calibrator: Double
    var hasError = false

    var body: some View {
        if hasError {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else {
            Image(nsImage: renderIcon())
        }
    }

    private func renderIcon() -> NSImage {
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else {
                logger.error("renderIcon: no CGContext available — icon will be blank")
                return false
            }

            let centerY = size / 2
            let barWidth = size * 0.8
            let barX = (size - barWidth) / 2
            let maxExtent = size / 2

            // Calibrator bar (extends up for positive, down for negative)
            let clamped = max(-1, min(1, calibrator))
            let magnitude = abs(clamped)
            let barHeight = CGFloat(magnitude) * maxExtent

            if barHeight > 0.5 {
                let color = UsageColor.cgColorFromCalibrator(calibrator)
                let barY: CGFloat = clamped >= 0 ? centerY : centerY - barHeight

                ctx.setFillColor(color)
                ctx.fill(CGRect(x: barX, y: barY, width: barWidth, height: barHeight))
            }

            // Center line — white, full width
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: centerY - 0.5, width: size, height: 1))

            return true
        }
        image.isTemplate = false
        return image
    }
}
