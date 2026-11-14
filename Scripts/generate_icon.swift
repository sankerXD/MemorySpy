import AppKit
import Foundation

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: generate_icon.swift <output.icns>\n", stderr)
    exit(1)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

func renderIconPNG(pixelSize: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    rep.size = NSSize(width: pixelSize, height: pixelSize)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(pixelSize)
    let inset = s * 0.08
    let cardRect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let cornerRadius = cardRect.width * 0.225
    let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: cornerRadius, yRadius: cornerRadius)

    if pixelSize >= 64 {
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -s * 0.018)
        shadow.shadowBlurRadius = s * 0.035
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
        shadow.set()
    }
    NSColor(calibratedRed: 0.08, green: 0.11, blue: 0.16, alpha: 1.0).setFill()
    cardPath.fill()

    NSShadow().set()
    cardPath.addClip()

    let bgGradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.14, green: 0.18, blue: 0.26, alpha: 1.0),
        NSColor(calibratedRed: 0.06, green: 0.09, blue: 0.14, alpha: 1.0),
    ])
    bgGradient?.draw(in: cardRect, angle: -90)

    let rimPath = NSBezierPath(
        roundedRect: cardRect.insetBy(dx: s * 0.008, dy: s * 0.008),
        xRadius: cornerRadius * 0.96,
        yRadius: cornerRadius * 0.96
    )
    rimPath.lineWidth = max(1.0, s * 0.012)
    NSColor.white.withAlphaComponent(0.15).setStroke()
    rimPath.stroke()

    // Segmented memory ring (10 chunky segments, 7 lit)
    let center = NSPoint(x: s / 2.0, y: s / 2.0)
    let ringRadius = cardRect.width * 0.285
    let ringWidth = cardRect.width * 0.125
    let segmentCount = 10
    let litCount = 7
    let stepAngle: CGFloat = 360.0 / CGFloat(segmentCount)
    let gapAngle: CGFloat = 11.5
    let arcSpan = stepAngle - gapAngle

    let segmentColors: [NSColor] = [
        NSColor(calibratedRed: 0.24, green: 0.80, blue: 0.98, alpha: 1.0),
        NSColor(calibratedRed: 0.22, green: 0.74, blue: 0.98, alpha: 1.0),
        NSColor(calibratedRed: 0.25, green: 0.65, blue: 0.98, alpha: 1.0),
        NSColor(calibratedRed: 0.32, green: 0.57, blue: 0.98, alpha: 1.0),
        NSColor(calibratedRed: 0.42, green: 0.50, blue: 0.97, alpha: 1.0),
        NSColor(calibratedRed: 0.56, green: 0.46, blue: 0.96, alpha: 1.0),
        NSColor(calibratedRed: 0.70, green: 0.44, blue: 0.94, alpha: 1.0),
    ]

    for idx in 0..<segmentCount {
        let startAngle = 90.0 - (gapAngle / 2.0) - CGFloat(idx) * stepAngle
        let endAngle = startAngle - arcSpan

        let segPath = NSBezierPath()
        segPath.appendArc(
            withCenter: center,
            radius: ringRadius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: true
        )
        segPath.lineWidth = ringWidth
        segPath.lineCapStyle = .butt

        if idx < litCount {
            segmentColors[idx].setStroke()
        } else {
            NSColor.white.withAlphaComponent(0.14).setStroke()
        }
        segPath.stroke()
    }

    let dotRadius = cardRect.width * 0.055
    let dotRect = NSRect(x: center.x - dotRadius, y: center.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
    NSColor.white.withAlphaComponent(0.88).setFill()
    NSBezierPath(ovalIn: dotRect).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

func appendBigEndianUInt32(_ data: inout Data, _ value: UInt32) {
    var be = value.bigEndian
    withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
}

let chunks: [(String, Int)] = [
    ("icp4", 16),
    ("ic11", 32),
    ("icp5", 32),
    ("ic12", 64),
    ("ic07", 128),
    ("ic13", 256),
    ("ic08", 256),
    ("ic14", 512),
    ("ic09", 512),
    ("ic10", 1024),
]

var pngCache: [Int: Data] = [:]
var body = Data()

for (tag, px) in chunks {
    let png: Data
    if let cached = pngCache[px] {
        png = cached
    } else {
        guard let rendered = renderIconPNG(pixelSize: px) else {
            fputs("Failed to render \(px)px icon\n", stderr)
            exit(1)
        }
        pngCache[px] = rendered
        png = rendered
    }

    body.append(contentsOf: tag.utf8)
    appendBigEndianUInt32(&body, UInt32(8 + png.count))
    body.append(png)
}

var icns = Data()
icns.append(contentsOf: "icns".utf8)
appendBigEndianUInt32(&icns, UInt32(8 + body.count))
icns.append(body)

try icns.write(to: outputURL)
