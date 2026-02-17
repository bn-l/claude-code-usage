import SwiftUI
import AppKit
import OSLog

private let logger = Logger(subsystem: "com.bml.claude-code-usage", category: "CalibratorIcon")

struct CalibratorIcon: View {
    let calibrator: Double
    let sessionUtilRatio: Double
    let dailyAllotmentRatio: Double
    let displayMode: MenuBarDisplayMode
    var hasError = false

    var body: some View {
        if hasError {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else {
            switch displayMode {
            case .calibrator: Image(nsImage: renderCalibrator())
            case .dualBar:    Image(nsImage: renderDualBar())
            }
        }
    }

    private func renderCalibrator() -> NSImage {
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else {
                logger.error("renderCalibrator: no CGContext available")
                return false
            }

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

            // Center line
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: centerY - 0.5, width: size, height: 1))

            return true
        }
        image.isTemplate = false
        return image
    }

    private func renderDualBar() -> NSImage {
        let size: CGFloat = 18
        let gap: CGFloat = 2
        let barWidth = (size - gap) / 2

        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else {
                logger.error("renderDualBar: no CGContext available")
                return false
            }

            // Bar 1 (left) — session utilization ratio, red→green
            let leftFill = CGFloat(min(max(sessionUtilRatio, 0), 1))
            let leftHeight = leftFill * size
            let leftColor = UsageColor.cgColorFromRatio(sessionUtilRatio)
            ctx.setFillColor(leftColor)
            ctx.fill(CGRect(x: 0, y: 0, width: barWidth, height: leftHeight))

            // Bar 2 (right) — daily allotment ratio, green→red (inverted)
            let rightFill = CGFloat(min(max(dailyAllotmentRatio, 0), 1))
            let rightHeight = rightFill * size
            let rightColor = UsageColor.cgColorFromRatioInverted(dailyAllotmentRatio)
            ctx.setFillColor(rightColor)
            ctx.fill(CGRect(x: barWidth + gap, y: 0, width: barWidth, height: rightHeight))

            return true
        }
        image.isTemplate = false
        return image
    }
}
