// Draws the Ronic DockPane logo (1024×1024 PNG): a white "R" on a dark background, with translucent
// window previews floating behind it, like thumbnails popping out of the Dock. Same geometry as the
// Ronic family (rounded square, SF Pro Rounded Black, glow, glass shine at the top).
//
//   swift branding/make-logo.swift branding/out/logo-1024.png
import AppKit
import CoreText

guard CommandLine.arguments.count == 2 else {
    print("usage: swift branding/make-logo.swift output.png"); exit(1)
}
let outputPath = CommandLine.arguments[1]

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let violet: UInt32 = 0x7C5CFF
let blue: UInt32 = 0x4F8BFF

/// Vector path of a letter (SF Pro Rounded Black, as in the other Ronic apps).
func glyphPath(_ char: String, size: CGFloat) -> CGPath {
    let font = CTFontCreateWithName("SFProRounded-Black" as CFString, size, nil)
    let fallback = NSFont.systemFont(ofSize: size, weight: .black) as CTFont
    let useFont = (CTFontCopyPostScriptName(font) as String).contains("Rounded") ? font : fallback
    var unichars = Array(char.utf16)
    var glyphs = [CGGlyph](repeating: 0, count: unichars.count)
    CTFontGetGlyphsForCharacters(useFont, &unichars, &glyphs, unichars.count)
    return CTFontCreatePathForGlyph(useFont, glyphs[0], nil)!
}

/// Deterministic pseudo-random generator: the logo comes out identical on every run.
struct LCG {
    var state: UInt64
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(Double(state >> 33) / Double(1 << 31))
    }
}

/// A small window: body, title bar with three dots, and a few "text" lines.
func drawWindow(_ ctx: CGContext, rect: CGRect, tint: UInt32, alpha: CGFloat) {
    let r = rect.width * 0.08
    let body = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    ctx.addPath(body)
    ctx.setFillColor(color(tint, 0.10 * alpha))
    ctx.fillPath()
    ctx.addPath(body)
    ctx.setStrokeColor(color(tint, 0.85 * alpha))
    ctx.setLineWidth(max(2, rect.width * 0.018))
    ctx.strokePath()

    let barH = rect.height * 0.16
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.setFillColor(color(tint, 0.35 * alpha))
    ctx.fill(CGRect(x: rect.minX, y: rect.maxY - barH, width: rect.width, height: barH))
    ctx.restoreGState()

    let dot = barH * 0.42
    for i in 0..<3 {
        ctx.setFillColor(color(0xFFFFFF, 0.75 * alpha))
        ctx.fillEllipse(in: CGRect(x: rect.minX + barH * 0.45 + CGFloat(i) * dot * 1.6,
                                   y: rect.maxY - barH / 2 - dot / 2, width: dot, height: dot))
    }
    let lineH = rect.height * 0.07
    for i in 0..<3 {
        let w = rect.width * [0.62, 0.45, 0.54][i]
        let y = rect.maxY - barH - lineH * (2.0 + CGFloat(i) * 1.9)
        let line = CGRect(x: rect.minX + rect.width * 0.1, y: y, width: w, height: lineH)
        ctx.addPath(CGPath(roundedRect: line, cornerWidth: lineH / 2, cornerHeight: lineH / 2, transform: nil))
        ctx.setFillColor(color(tint, 0.55 * alpha))
        ctx.fillPath()
    }
}

let px = 1024
let s = CGFloat(px)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setShouldAntialias(true)

// ---- Background: dark rounded square with a violet tint ----
let inset = s * 0.04
let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
let radius = rect.width * 0.225
let bg = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.saveGState()
ctx.addPath(bg)
ctx.clip()

let base = CGGradient(colorsSpace: cs, colors: [color(0x110D24), color(0x05040C)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])

// ---- Floating window previews, in depth layers (dim and small far away, bright and big up front) ----
var rng = LCG(state: 0xD0C_2026)
let columns = 5
let rows = 6
let cellW = rect.width / CGFloat(columns)
let cellH = rect.height / CGFloat(rows)
for row in 0..<rows {
    for col in 0..<columns {
        guard rng.next() > 0.18 else { continue }          // a few gaps keep it from looking like a grid
        let depth = 0.35 + rng.next() * 0.65
        let w = cellW * (0.62 + 0.38 * depth)
        let h = w * 0.66
        let x = rect.minX + cellW * CGFloat(col) + (cellW - w) * rng.next() + (row % 2 == 0 ? cellW * 0.25 : -cellW * 0.1)
        let y = rect.minY + cellH * CGFloat(row) + (cellH - h) * rng.next()
        let tint = rng.next() > 0.5 ? violet : blue
        drawWindow(ctx, rect: CGRect(x: x, y: y, width: w, height: h), tint: tint, alpha: 0.25 + 0.6 * depth)
    }
}

// ---- Dark vignette in the center: the R stands out from the windows ----
let vignette = CGGradient(colorsSpace: cs, colors: [color(0x000000, 0.82), color(0x000000, 0)] as CFArray,
                          locations: [0, 1])!
ctx.drawRadialGradient(vignette, startCenter: CGPoint(x: s / 2, y: s / 2), startRadius: 0,
                       endCenter: CGPoint(x: s / 2, y: s / 2), endRadius: s * 0.44, options: [])

// ---- The white R with a violet glow ----
let glyph = glyphPath("R", size: s * 0.56)
let gb = glyph.boundingBoxOfPath
let shiftX = s * 0.06                                      // the "R + Dock" pair is what gets centered
var t = CGAffineTransform(translationX: s / 2 - gb.width / 2 - gb.minX - shiftX, y: (s - gb.height) / 2 - gb.minY)
let letter = glyph.copy(using: &t)!
let lb = letter.boundingBoxOfPath

ctx.saveGState()
ctx.setShadow(offset: .zero, blur: s * 0.06, color: color(violet, 0.75))
ctx.addPath(letter)
ctx.setFillColor(color(0xFFFFFF))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(letter)
ctx.clip()
let metal = CGGradient(colorsSpace: cs, colors: [color(0xFFFFFF), color(0xFFFFFF), color(0xE2DEFF)] as CFArray,
                       locations: [0, 0.55, 1])!
ctx.drawLinearGradient(metal, start: CGPoint(x: 0, y: lb.maxY), end: CGPoint(x: 0, y: lb.minY), options: [])
ctx.restoreGState()

// ---- A tiny glowing Dock next to the R (where JustTerminal has its cursor) ----
let dockW = s * 0.13, dockH = s * 0.042
let dock = CGRect(x: lb.maxX + s * 0.03, y: lb.minY, width: dockW, height: dockH)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: s * 0.03, color: color(violet, 0.95))
ctx.addPath(CGPath(roundedRect: dock, cornerWidth: dockH / 2, cornerHeight: dockH / 2, transform: nil))
ctx.setFillColor(color(0x9D85FF))
ctx.fillPath()
ctx.restoreGState()
let dot = dockH * 0.42
for i in 0..<3 {
    let cx = dock.minX + dockW * (0.25 + 0.25 * CGFloat(i))
    ctx.setFillColor(color(0xFFFFFF, 0.95))
    ctx.fillEllipse(in: CGRect(x: cx - dot / 2, y: dock.midY - dot / 2, width: dot, height: dot))
}

// ---- Glass shine at the top (same as the Ronic family) ----
let shine = CGGradient(colorsSpace: cs, colors: [color(0xFFFFFF, 0.16), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(shine, startCenter: CGPoint(x: s * 0.3, y: s * 0.98), startRadius: 0,
                       endCenter: CGPoint(x: s * 0.3, y: s * 0.98), endRadius: s * 0.7, options: [])
ctx.restoreGState()

// Thin glass border.
ctx.addPath(bg)
ctx.setStrokeColor(color(0xFFFFFF, 0.10))
ctx.setLineWidth(max(1, s * 0.004))
ctx.strokePath()

let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath)")
