// Generates the 1024px App Store icon: a cream receipt with a zigzag bottom
// edge on the brand terracotta gradient (Theme.swift palette). Run from the
// repo root:  swift scripts/generate-app-icon.swift
// The output PNG is committed; this script exists to regenerate it.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
// noneSkipLast = opaque bitmap: the App Store marketing icon must have NO alpha.
let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
)!

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [
        CGFloat((hex >> 16) & 0xFF) / 255,
        CGFloat((hex >> 8) & 0xFF) / 255,
        CGFloat(hex & 0xFF) / 255,
        alpha,
    ])!
}

// Brand gradient: terracotta #E8602C -> deep terracotta #C2461A (AccentTheme).
func drawBackgroundGradient() {
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(0xE8602C), color(0xC2461A)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: CGFloat(size)), end: CGPoint(x: 0, y: 0),
        options: []
    )
}

drawBackgroundGradient()

// Receipt body: cream (#FBF6F0) rect, rounded at the top, square at the bottom
// (the zigzag is cut out of the square edge below).
let receipt = CGRect(x: 292, y: 264, width: 440, height: 580)
let body = CGMutablePath()
body.addRoundedRect(in: receipt, cornerWidth: 44, cornerHeight: 44)
body.addRect(CGRect(x: receipt.minX, y: receipt.minY, width: receipt.width, height: 60))
ctx.addPath(body)
ctx.setFillColor(color(0xFBF6F0))
ctx.fillPath()

// Zigzag bottom edge: clip to 8 notch triangles, redraw the same gradient so
// the notches read as cut-outs revealing the background.
ctx.saveGState()
let teeth = 8
let toothW = receipt.width / CGFloat(teeth)
let notches = CGMutablePath()
for i in 0..<teeth {
    let x0 = receipt.minX + CGFloat(i) * toothW
    notches.move(to: CGPoint(x: x0, y: receipt.minY))
    notches.addLine(to: CGPoint(x: x0 + toothW / 2, y: receipt.minY + 34))
    notches.addLine(to: CGPoint(x: x0 + toothW, y: receipt.minY))
    notches.closeSubpath()
}
ctx.addPath(notches)
ctx.clip()
drawBackgroundGradient()
ctx.restoreGState()

// Receipt detail: three faded item lines + one bold total bar.
ctx.setFillColor(color(0xC2461A, alpha: 0.28))
for (i, w) in [292, 236, 264].enumerated() {
    ctx.fill(CGRect(x: Int(receipt.minX) + 56, y: 716 - i * 84, width: w, height: 26))
}
ctx.setFillColor(color(0xC2461A))
ctx.fill(CGRect(x: Int(receipt.minX) + 56, y: 396, width: 174, height: 34))

let image = ctx.makeImage()!
let outPath = "Snapceipt/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
let dest = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: outPath) as CFURL, UTType.png.identifier as CFString, 1, nil
)!
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("PNG write failed") }
print("wrote \(outPath)")
