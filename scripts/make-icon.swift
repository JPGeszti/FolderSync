// Draws the FolderSync app icon: a source folder syncing one way into a destination folder,
// above a small commit graph. Run through scripts/make-icon.sh, which turns the 1024 px PNG
// into Resources/AppIcon.icns.
//
//   swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: make-icon.swift <output.png>\n".data(using: .utf8)!)
    exit(2)
}

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high

// Background tile on Apple's icon grid: 824 pt body, centered, with a soft drop shadow.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let tile = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 28
shadow.set()
rgb(0x3A45D6).setFill()
tile.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(colors: [rgb(0x5B7CFF), rgb(0x3B3FC9), rgb(0x2B238F)], atLocations: [0, 0.55, 1],
           colorSpace: .sRGB)!.draw(in: tile, angle: -90)
// Subtle top highlight.
NSGraphicsContext.saveGraphicsState()
tile.addClip()
NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])!
    .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
NSGraphicsContext.restoreGraphicsState()

/// A folder: darker back panel with a tab, and a lighter front panel slightly lower.
func folder(in r: NSRect, back: NSColor, front: NSColor) {
    let tabWidth = r.width * 0.42, tabHeight = r.height * 0.14, radius = r.width * 0.09
    let backPath = NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height - tabHeight * 0.6),
                                xRadius: radius, yRadius: radius)
    backPath.append(NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.maxY - tabHeight * 1.6, width: tabWidth, height: tabHeight * 1.6),
                                 xRadius: radius * 0.8, yRadius: radius * 0.8))
    back.setFill()
    backPath.fill()

    NSGraphicsContext.saveGraphicsState()
    let s = NSShadow()
    s.shadowColor = NSColor.black.withAlphaComponent(0.22)
    s.shadowOffset = NSSize(width: 0, height: -6)
    s.shadowBlurRadius = 14
    s.set()
    front.setFill()
    NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height * 0.78),
                 xRadius: radius, yRadius: radius).fill()
    NSGraphicsContext.restoreGraphicsState()
}

let folderSize = NSSize(width: 250, height: 200)
folder(in: NSRect(origin: NSPoint(x: 182, y: 476), size: folderSize), back: rgb(0x9DB8FF), front: rgb(0xD3E0FF))
folder(in: NSRect(origin: NSPoint(x: 592, y: 476), size: folderSize), back: rgb(0xD9E3FF), front: .white)

// One-way arrow between the folders.
let arrow = NSBezierPath()
let ay: CGFloat = 562
arrow.move(to: NSPoint(x: 452, y: ay))
arrow.line(to: NSPoint(x: 552, y: ay))
arrow.lineWidth = 26
arrow.lineCapStyle = .round
NSColor.white.setStroke()
arrow.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 530, y: ay + 34))
head.line(to: NSPoint(x: 572, y: ay))
head.line(to: NSPoint(x: 530, y: ay - 34))
head.lineWidth = 26
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.stroke()

// Commit graph: a line of history with added / modified / archived nodes.
let gy: CGFloat = 318
let line = NSBezierPath()
line.move(to: NSPoint(x: 250, y: gy))
line.line(to: NSPoint(x: 774, y: gy))
line.lineWidth = 18
line.lineCapStyle = .round
NSColor.white.withAlphaComponent(0.75).setStroke()
line.stroke()
for (x, color) in [(CGFloat(300), rgb(0x34C759)), (512, rgb(0xFF9F0A)), (724, rgb(0xBF5AF2))] {
    let ring = NSRect(x: x - 50, y: gy - 50, width: 100, height: 100)
    NSColor.white.setFill()
    NSBezierPath(ovalIn: ring).fill()
    color.setFill()
    NSBezierPath(ovalIn: ring.insetBy(dx: 15, dy: 15)).fill()
}

NSGraphicsContext.current = nil
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
