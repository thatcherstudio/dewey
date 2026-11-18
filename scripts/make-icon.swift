// Draws Dewey's app icon (three catalog cards with coloured tabs on a blue rounded square) and
// writes mac/Resources/AppIcon.icns. Run from the repo root after changing the drawing:
//   swift scripts/make-icon.swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fillGradient(_ ctx: CGContext, _ path: CGPath, top: CGColor, bottom: CGColor) {
    let rect = path.boundingBox
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray,
                       locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY),
                           options: [])
    ctx.restoreGState()
}

/// The icon on a 1024 × 1024 canvas (origin bottom left), inside Apple's 824-point grid.
func draw(_ ctx: CGContext) {
    let tile = roundedRect(CGRect(x: 100, y: 100, width: 824, height: 824), 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.28))
    ctx.addPath(tile)
    ctx.setFillColor(color(0x2A55B8))
    ctx.fillPath()
    ctx.restoreGState()
    fillGradient(ctx, tile, top: color(0x4C86E8), bottom: color(0x1E3A8C))

    // back to front: each card lower, its tab further right
    let cards: [(y: CGFloat, tabX: CGFloat, tab: UInt32)] = [(402, 262, 0xF5A623), (304, 437, 0x34C77B),
                                                             (206, 612, 0xFF6F59)]
    for (i, c) in cards.enumerated() {
        let card = CGRect(x: 232, y: c.y, width: 560, height: 360)
        let tab = roundedRect(CGRect(x: c.tabX, y: card.maxY - 30, width: 150, height: 86), 20)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0x0B1B45, 0.35))
        ctx.addPath(tab)
        ctx.setFillColor(color(c.tab))
        ctx.fillPath()
        ctx.addPath(roundedRect(card, 30))
        ctx.setFillColor(color(0xFFF9EE))
        ctx.fillPath()
        ctx.restoreGState()
        fillGradient(ctx, roundedRect(card, 30), top: color(0xFFFBF3), bottom: color(0xEFE4CF))
        if i == cards.count - 1 {  // the front card: lines of a catalog entry
            ctx.setFillColor(color(0xB9C6DE))
            for (j, w) in [380.0, 300.0, 340.0, 220.0].enumerated() {
                ctx.addPath(roundedRect(CGRect(x: 282, y: card.maxY - 92 - CGFloat(j) * 62, width: w, height: 24), 12))
                ctx.fillPath()
            }
        }
    }
}

func png(size: Int) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    draw(ctx)
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return data as Data
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "AppIcon-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    try png(size: points).write(to: iconset.appending(path: "icon_\(points)x\(points).png"))
    try png(size: points * 2).write(to: iconset.appending(path: "icon_\(points)x\(points)@2x.png"))
}
let out = URL(fileURLWithPath: "mac/Resources/AppIcon.icns")
try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
if CommandLine.arguments.count > 1 {  // a preview PNG, to look at the drawing
    try png(size: 1024).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
print("Wrote \(out.path)")
