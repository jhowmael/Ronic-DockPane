// Draws the Ronic DockPane logo (1024×1024 PNG): two stacked window cards above a Dock bar.
//
//   swift branding/make-logo.swift branding/out/logo-1024.png
import AppKit

guard CommandLine.arguments.count == 2 else {
    print("usage: swift branding/make-logo.swift output.png"); exit(1)
}
let outputPath = CommandLine.arguments[1]
let accentTop = NSColor(srgbRed: 0.49, green: 0.36, blue: 1.00, alpha: 1)
let accentBottom = NSColor(srgbRed: 0.23, green: 0.51, blue: 0.97, alpha: 1)

let image = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { rect in
    // Rounded-square background with a diagonal gradient (the macOS icon shape).
    let tile = NSBezierPath(roundedRect: rect.insetBy(dx: 40, dy: 40), xRadius: 200, yRadius: 200)
    NSGradient(colors: [accentTop, accentBottom])?.draw(in: tile, angle: -60)

    // Back window card, translucent.
    NSColor.white.withAlphaComponent(0.42).setFill()
    NSBezierPath(roundedRect: NSRect(x: 250, y: 470, width: 430, height: 300), xRadius: 52, yRadius: 52).fill()

    // Front window card with title dots and list rows.
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 340, y: 340, width: 440, height: 300), xRadius: 52, yRadius: 52).fill()
    accentTop.withAlphaComponent(0.85).setFill()
    for index in 0..<3 {
        NSBezierPath(ovalIn: NSRect(x: 382 + CGFloat(index) * 38, y: 556, width: 22, height: 22)).fill()
    }
    accentBottom.withAlphaComponent(0.55).setFill()
    NSBezierPath(roundedRect: NSRect(x: 390, y: 480, width: 300, height: 30), xRadius: 15, yRadius: 15).fill()
    NSBezierPath(roundedRect: NSRect(x: 390, y: 420, width: 240, height: 30), xRadius: 15, yRadius: 15).fill()

    // Dock bar with four icons.
    NSColor.white.withAlphaComponent(0.92).setFill()
    NSBezierPath(roundedRect: NSRect(x: 230, y: 130, width: 564, height: 130), xRadius: 42, yRadius: 42).fill()
    accentTop.withAlphaComponent(0.8).setFill()
    for index in 0..<4 {
        NSBezierPath(ovalIn: NSRect(x: 290 + CGFloat(index) * 118, y: 160, width: 70, height: 70)).fill()
    }
    return true
}

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    print("could not encode the logo"); exit(1)
}
try png.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath)")
