import AppKit

enum RingIconRenderer {
    static let segmentCount = 10

    static func renderRingImage(
        fraction: Double,
        pressure: MemoryPressureLevel,
        monochromeOnly: Bool
    ) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let clamped = min(1.0, max(0.0, fraction))
        let filledSegments: Int
        if clamped <= 0.005 {
            filledSegments = 0
        } else {
            filledSegments = max(1, min(segmentCount, Int((clamped * Double(segmentCount)).rounded())))
        }

        let accentColor: NSColor?
        if !monochromeOnly {
            switch pressure {
            case .warning:
                accentColor = NSColor.systemOrange
            case .critical:
                accentColor = NSColor.systemRed
            case .normal, .unknown:
                accentColor = clamped >= 0.88 ? NSColor.systemOrange : nil
            }
        } else {
            accentColor = nil
        }

        let image = NSImage(size: size, flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius: CGFloat = 6.2
            let lineWidth: CGFloat = 3.0
            let stepAngle: CGFloat = 360.0 / CGFloat(segmentCount)
            let gapAngle: CGFloat = 11.0
            let arcSpan: CGFloat = stepAngle - gapAngle

            let baseColor = accentColor ?? NSColor.labelColor
            let litColor = baseColor
            let unlitColor = baseColor.withAlphaComponent(accentColor == nil ? 0.22 : 0.26)

            for idx in 0..<segmentCount {
                // Start cleanly just clockwise of 12 o'clock (90 deg) so the top gap is centered
                let startAngle = 90.0 - (gapAngle / 2.0) - CGFloat(idx) * stepAngle
                let endAngle = startAngle - arcSpan

                let segmentPath = NSBezierPath()
                segmentPath.appendArc(
                    withCenter: center,
                    radius: radius,
                    startAngle: startAngle,
                    endAngle: endAngle,
                    clockwise: true
                )
                segmentPath.lineWidth = lineWidth
                segmentPath.lineCapStyle = .butt

                if idx < filledSegments {
                    litColor.setStroke()
                } else {
                    unlitColor.setStroke()
                }
                segmentPath.stroke()
            }

            return true
        }

        image.isTemplate = (accentColor == nil)
        return image
    }
}
