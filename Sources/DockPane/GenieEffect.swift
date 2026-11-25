import AppKit
import QuartzCore

/// Closing animation: the panel shrinks into its Dock icon in one smooth, continuous move, narrowing a little
/// faster along the Dock than away from it, and fades out on the way, as if pulled in. It plays in its own
/// click-through window, so the real panel is already gone and nothing waits for it.
enum GenieEffect {
    static let duration: TimeInterval = 0.34

    /// Overlays still animating. They are kept here until their animation ends.
    private static var overlays: [NSWindow] = []

    /// Plays the effect for `image`, which covers `source`, into the Dock icon at `icon` (both in screen points).
    static func play(_ image: CGImage, from source: CGRect, into icon: CGRect, edge: DockEdge, level: NSWindow.Level) {
        guard source.width > 2, source.height > 2 else { return }
        let bounds = source.union(icon).insetBy(dx: -24, dy: -24).integral

        let window = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = level
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let view = NSView(frame: NSRect(origin: .zero, size: bounds.size))
        view.wantsLayer = true
        window.contentView = view
        guard let root = view.layer else { return }

        let from = CGPoint(x: source.midX - bounds.minX, y: source.midY - bounds.minY)
        let to = CGPoint(x: icon.midX - bounds.minX, y: icon.midY - bounds.minY)

        let layer = CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = image
        layer.contentsGravity = .resize
        layer.contentsScale = window.backingScaleFactor
        layer.bounds = CGRect(origin: .zero, size: source.size)
        layer.position = from
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: -6)
        root.addSublayer(layer)
        CATransaction.commit()

        window.orderFrontRegardless()
        overlays.append(window)

        // Ends at about half the icon's size; it has faded out by then.
        let endWidth = max(0.03, icon.width * 0.5 / source.width)
        let endHeight = max(0.03, icon.height * 0.5 / source.height)
        // The side along the Dock narrows first, which reads as being pulled into the icon.
        let alongDockIsX = edge == .bottom
        let fast: [CGFloat] = [1, 0.62, alongDockIsX ? endWidth : endHeight]
        let slow: [CGFloat] = [1, 0.8, alongDockIsX ? endHeight : endWidth]

        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: from)
        move.toValue = NSValue(point: to)

        let scaleX = CAKeyframeAnimation(keyPath: "transform.scale.x")
        scaleX.values = alongDockIsX ? fast : slow
        scaleX.keyTimes = [0, 0.5, 1]
        let scaleY = CAKeyframeAnimation(keyPath: "transform.scale.y")
        scaleY.values = alongDockIsX ? slow : fast
        scaleY.keyTimes = [0, 0.5, 1]

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 0.95, 0]
        fade.keyTimes = [0, 0.45, 1]

        let group = CAAnimationGroup()
        group.animations = [move, scaleX, scaleY, fade]
        group.duration = duration
        // Gentle start and a soft landing: no jolt at either end.
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            window.orderOut(nil)
            overlays.removeAll { $0 === window }
        }
        layer.add(group, forKey: "closeIntoDock")
        CATransaction.commit()
    }

    /// Removes any effect still playing (the panel is coming back).
    static func cancelAll() {
        for window in overlays { window.orderOut(nil) }
        overlays.removeAll()
    }

    /// Draws `view` into an image at `scale`, optionally over a dark rounded background like the HUD material.
    /// The real background blur is done by the window server and cannot be captured, and it is not missed
    /// during a third of a second.
    static func snapshot(of view: NSView, scale: CGFloat, background: Bool) -> CGImage? {
        let size = view.bounds.size
        guard size.width >= 1, size.height >= 1,
              let rep = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: Int(size.width * scale),
                  pixelsHigh: Int(size.height * scale),
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        if background {
            let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size).insetBy(dx: 0.25, dy: 0.25),
                                    xRadius: 12, yRadius: 12)
            NSColor(calibratedWhite: 0.13, alpha: 0.94).setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.12).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
        view.displayIgnoringOpacity(view.bounds, in: context)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
}
