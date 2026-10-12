// Makes the phone PWA's icons (web/) from the Mac app icon, so both look the same. No packages: CoreGraphics + ImageIO.
//   swift scripts/pwa-icons.swift            write the PNGs into web/
// Source: docs/design/icon/AppIcon-1024.png (light) and AppIcon-dark-1024.png. Their body (the rounded square) is the
// 824 px square at (100, 100) of the Apple macOS grid; the rest is transparent margin.
//   icon-192.png, icon-512.png   purpose "any": the body, its rounded corners transparent (as on the Mac).
//   icon-maskable-512.png        purpose "maskable": full bleed on the body's own gradient; the artwork stays inside the
//                                80 % safe circle (it reaches 37 % of the side from the centre).
//   apple-touch-icon.png         180, opaque (iOS rounds it itself): the maskable drawing.
//   favicon-32.png, favicon-dark-32.png   the body, light and dark.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconDir = root.appendingPathComponent("docs/design/icon")
let web = root.appendingPathComponent("web")
let body = CGRect(x: 100, y: 100, width: 824, height: 824)

func load(_ name: String) -> CGImage {
    let url = iconDir.appendingPathComponent(name)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        fatalError("cannot read \(url.path)")
    }
    precondition(img.width == 1024 && img.height == 1024, "\(name): expected 1024x1024")
    return img
}

func context(_ side: Int, opaque: Bool) -> CGContext {
    let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    return ctx
}

func write(_ img: CGImage, _ name: String) {
    let url = web.appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    precondition(CGImageDestinationFinalize(dest), "cannot write \(url.path)")
    print("pwa-icons: \(name) \(img.width)x\(img.height)\(img.alphaInfo == .noneSkipLast ? " opaque" : "")")
}

/// The body, scaled to `side`.
func plain(_ icon: CGImage, _ side: Int) -> CGImage {
    let crop = icon.cropping(to: body)!
    let ctx = context(side, opaque: false)
    ctx.draw(crop, in: CGRect(x: 0, y: 0, width: side, height: side))
    return ctx.makeImage()!
}

/// RGB of one pixel of the 1024 image (y from the top), 0...1.
func pixel(_ icon: CGImage, _ x: Int, _ y: Int) -> [CGFloat] {
    let ctx = context(1, opaque: false)
    ctx.draw(icon, in: CGRect(x: -x, y: -(icon.height - 1 - y), width: icon.width, height: icon.height))
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    return [CGFloat(p[0]) / 255, CGFloat(p[1]) / 255, CGFloat(p[2]) / 255]
}

/// Full bleed: the body's own gradient under the body, so its rounded corners disappear into the same colours.
/// The gradient is a plane fitted to four points inside the body's corners (per channel), drawn along its slope.
/// Opaque.
func bleed(_ icon: CGImage, _ side: Int) -> CGImage {
    let lo = 170, hi = 854, span = CGFloat(hi - lo)
    let tl = pixel(icon, lo, lo), tr = pixel(icon, hi, lo), bl = pixel(icon, lo, hi), br = pixel(icon, hi, hi)
    // Per channel: colour = mean + gx * (x - 512) + gy * (y - 512), x and y in the 1024 image (y down).
    var gx: [CGFloat] = [], gy: [CGFloat] = [], mean: [CGFloat] = []
    for c in 0..<3 {
        let across: CGFloat = (tr[c] - tl[c]) + (br[c] - bl[c])
        let down: CGFloat = (bl[c] - tl[c]) + (br[c] - tr[c])
        let sum: CGFloat = tl[c] + tr[c] + bl[c] + br[c]
        gx.append(across / 2 / span); gy.append(down / 2 / span); mean.append(sum / 4)
    }
    // Along the green channel's slope, far enough to cover the body's corners.
    let len = max(hypot(gx[1], gy[1]), 1e-9)
    let (dx, dy) = (gx[1] / len, gy[1] / len)
    let reach: CGFloat = 412 * 1.5
    let colour = { (t: CGFloat) in
        CGColor(srgbRed: mean[0] + (gx[0] * dx + gy[0] * dy) * t, green: mean[1] + (gx[1] * dx + gy[1] * dy) * t,
                blue: mean[2] + (gx[2] * dx + gy[2] * dy) * t, alpha: 1)
    }
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [colour(-reach), colour(reach)] as CFArray, locations: [0, 1])!
    // Body coordinates (centre 412, y down) to the canvas (y up).
    let s = CGFloat(side), k = s / 824
    let point = { (u: CGFloat, v: CGFloat) in CGPoint(x: (412 + u) * k, y: s - (412 + v) * k) }
    let ctx = context(side, opaque: true)
    ctx.drawLinearGradient(g, start: point(-dx * reach, -dy * reach), end: point(dx * reach, dy * reach),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.draw(icon.cropping(to: body)!, in: CGRect(x: 0, y: 0, width: s, height: s))
    return ctx.makeImage()!
}

let light = load("AppIcon-1024.png"), dark = load("AppIcon-dark-1024.png")
write(plain(light, 192), "icon-192.png")
write(plain(light, 512), "icon-512.png")
write(bleed(light, 512), "icon-maskable-512.png")
write(bleed(light, 180), "apple-touch-icon.png")
write(plain(light, 32), "favicon-32.png")
write(plain(dark, 32), "favicon-dark-32.png")
