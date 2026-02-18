import SwiftUI
import AppKit
import OSLog

private let logger = Logger(subsystem: "com.bml.clacal", category: "CalibratorIcon")

struct CalibratorIcon: View {
    let calibrator: Double
    let sessionDeviation: Double
    let dailyDeviation: Double
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
        let centerY = size / 2
        let maxExtent = size / 2

        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else {
                logger.error("renderDualBar: no CGContext available")
                return false
            }

            // Left bar — session deviation (positive = over-pacing, negative = under)
            let sClamped = max(-1, min(1, sessionDeviation))
            let sHeight = CGFloat(abs(sClamped)) * maxExtent
            if sHeight > 0.5 {
                ctx.setFillColor(UsageColor.cgColorFromCalibrator(sClamped))
                let barY: CGFloat = sClamped >= 0 ? centerY : centerY - sHeight
                ctx.fill(CGRect(x: 0, y: barY, width: barWidth, height: sHeight))
            }

            // Right bar — daily allotment deviation (positive = over budget, negative = under)
            let dClamped = max(-1, min(1, dailyDeviation))
            let dHeight = CGFloat(abs(dClamped)) * maxExtent
            if dHeight > 0.5 {
                ctx.setFillColor(UsageColor.cgColorFromCalibrator(dClamped))
                let barY: CGFloat = dClamped >= 0 ? centerY : centerY - dHeight
                ctx.fill(CGRect(x: barWidth + gap, y: barY, width: barWidth, height: dHeight))
            }

            // Contiguous white center line across both bars
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: centerY - 0.5, width: size, height: 1))

            return true
        }
        image.isTemplate = false
        return image
    }
}
