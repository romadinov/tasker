import AppKit
import ImageIO
import UniformTypeIdentifiers
// Usage: prepare-icon <source.png> <outdir>
// iOS: tile cropped to its edges, opaque (iOS applies its own mask). macOS: tile on a transparent 1024 canvas (824 px shape).
let srcURL = URL(fileURLWithPath: CommandLine.arguments[1])
let out = CommandLine.arguments[2]
let source = CGImageSourceCreateWithURL(srcURL as CFURL, nil)!
let img = CGImageSourceCreateImageAtIndex(source, 0, nil)!
let W = CGFloat(img.width)
let inset = W * 0.0855   // the tile occupies ~8.5%…91.5% of the source
let tile = img.cropping(to: CGRect(x: inset, y: inset, width: W - 2 * inset, height: W - 2 * inset))!

func write(_ cg: CGImage, _ name: String) {
    let url = URL(fileURLWithPath: "\(out)/\(name)")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cg, nil)
    CGImageDestinationFinalize(dest)
}

func render(_ size: Int, mac: Bool) -> CGImage {
    let info: UInt32 = mac ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)!
    ctx.interpolationQuality = .high
    let s = CGFloat(size)
    if mac {
        let shape = s * 824 / 1024
        let r = CGRect(x: (s - shape) / 2, y: (s - shape) / 2, width: shape, height: shape)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: shape * 0.2237, cornerHeight: shape * 0.2237, transform: nil))
        ctx.clip()
        ctx.draw(tile, in: r)
    } else {
        ctx.draw(tile, in: CGRect(x: 0, y: 0, width: s, height: s))
    }
    return ctx.makeImage()!
}

write(render(1024, mac: false), "icon-1024.png")
for s in [16, 32, 64, 128, 256, 512, 1024] { write(render(s, mac: true), "mac-\(s).png") }
