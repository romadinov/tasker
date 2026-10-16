import AppKit
// Draws the app icon: violet gradient squircle with a checked circle.
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let rect = CGRect(x: 0, y: 0, width: size, height: size)
let path = CGPath(roundedRect: rect.insetBy(dx: 0, dy: 0), cornerWidth: 0, cornerHeight: 0, transform: nil)
ctx.addPath(path); ctx.clip()
let colors = [NSColor(red: 0.47, green: 0.36, blue: 0.93, alpha: 1).cgColor, NSColor(red: 0.27, green: 0.20, blue: 0.62, alpha: 1).cgColor] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
ctx.setStrokeColor(NSColor.white.cgColor)
ctx.setLineWidth(56)
ctx.strokeEllipse(in: rect.insetBy(dx: 250, dy: 250))
ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.setLineWidth(64)
ctx.move(to: CGPoint(x: 395, y: 520)); ctx.addLine(to: CGPoint(x: 480, y: 430)); ctx.addLine(to: CGPoint(x: 650, y: 610))
ctx.strokePath()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
