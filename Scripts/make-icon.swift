// Draws Decanter's app icon: a glass decanter of red wine on a deep wine-coloured tile.
// Usage: swift Scripts/make-icon.swift <output.png>   (1024×1024; bundle.sh turns it into an .icns)
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpaceCreateDeviceRGB()

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func linear(_ colors: [CGColor], from start: CGPoint, to end: CGPoint, in path: CGPath) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(gradient, start: start, end: end, options: [])
    ctx.restoreGState()
}

// The tile, on Apple's 1024 grid: 824 pt square, continuous corners, soft drop shadow.
let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let tile = CGPath(roundedRect: tileRect, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(tile)
ctx.setFillColor(color(0x3A0A18))
ctx.fillPath()
ctx.restoreGState()
linear([color(0x7A1A33), color(0x2B0712)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100), in: tile)

// The decanter: a wide, flat-bottomed bowl rising into a slim neck with a lip.
let cx: CGFloat = 512
let glass = CGMutablePath()
glass.move(to: CGPoint(x: cx - 46, y: 800))                      // left of the lip
glass.addLine(to: CGPoint(x: cx - 46, y: 770))
glass.addCurve(to: CGPoint(x: cx - 38, y: 560), control1: CGPoint(x: cx - 34, y: 740), control2: CGPoint(x: cx - 38, y: 640))
glass.addCurve(to: CGPoint(x: cx - 300, y: 300), control1: CGPoint(x: cx - 60, y: 470), control2: CGPoint(x: cx - 300, y: 440))
glass.addCurve(to: CGPoint(x: cx - 230, y: 210), control1: CGPoint(x: cx - 300, y: 245), control2: CGPoint(x: cx - 270, y: 215))
glass.addLine(to: CGPoint(x: cx + 230, y: 210))
glass.addCurve(to: CGPoint(x: cx + 300, y: 300), control1: CGPoint(x: cx + 270, y: 215), control2: CGPoint(x: cx + 300, y: 245))
glass.addCurve(to: CGPoint(x: cx + 38, y: 560), control1: CGPoint(x: cx + 300, y: 440), control2: CGPoint(x: cx + 60, y: 470))
glass.addCurve(to: CGPoint(x: cx + 46, y: 770), control1: CGPoint(x: cx + 38, y: 640), control2: CGPoint(x: cx + 34, y: 740))
glass.addLine(to: CGPoint(x: cx + 46, y: 800))
glass.closeSubpath()

// Shadow under the glass, then the glass body.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color(0x000000, 0.45))
ctx.addPath(glass)
ctx.setFillColor(color(0xFFFFFF, 0.16))
ctx.fillPath()
ctx.restoreGState()
linear([color(0xFFFFFF, 0.30), color(0xFFFFFF, 0.08)], from: CGPoint(x: cx - 300, y: 500),
       to: CGPoint(x: cx + 300, y: 300), in: glass)

// Wine, filling the bowl up to a gently curved surface.
ctx.saveGState()
ctx.addPath(glass)
ctx.clip()
let wine = CGMutablePath()
wine.move(to: CGPoint(x: 0, y: 372))
wine.addCurve(to: CGPoint(x: size, y: 372), control1: CGPoint(x: 340, y: 352), control2: CGPoint(x: 684, y: 352))
wine.addLine(to: CGPoint(x: size, y: 0))
wine.addLine(to: CGPoint(x: 0, y: 0))
wine.closeSubpath()
linear([color(0xE0284F), color(0x8E0E2C), color(0x5C0619)], from: CGPoint(x: cx, y: 372),
       to: CGPoint(x: cx, y: 210), in: wine)
// The wine's surface, a lighter band catching the light.
let surface = CGPath(ellipseIn: CGRect(x: cx - 268, y: 352, width: 536, height: 34), transform: nil)
ctx.addPath(surface)
ctx.setFillColor(color(0xFF6B86, 0.55))
ctx.fillPath()
ctx.restoreGState()

// Glass rim outline.
ctx.addPath(glass)
ctx.setStrokeColor(color(0xFFFFFF, 0.75))
ctx.setLineWidth(10)
ctx.setLineJoin(.round)
ctx.strokePath()

// Lip of the neck.
let lip = CGPath(roundedRect: CGRect(x: cx - 62, y: 780, width: 124, height: 34), cornerWidth: 17, cornerHeight: 17, transform: nil)
ctx.addPath(lip)
ctx.setFillColor(color(0xFFFFFF, 0.85))
ctx.fillPath()

// Highlight down the left side of the bowl.
let highlight = CGMutablePath()
highlight.move(to: CGPoint(x: cx - 240, y: 290))
highlight.addCurve(to: CGPoint(x: cx - 110, y: 450), control1: CGPoint(x: cx - 250, y: 380), control2: CGPoint(x: cx - 170, y: 430))
ctx.addPath(highlight)
ctx.setStrokeColor(color(0xFFFFFF, 0.7))
ctx.setLineWidth(18)
ctx.setLineCap(.round)
ctx.strokePath()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
