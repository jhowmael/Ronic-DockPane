import AppKit

/// Watches the mouse globally and reports which app icon in the Dock it is over.
///
/// Idle cost is essentially zero: the global monitor is event-driven and there are no timers.
/// Only while the pointer is inside the Dock's edge strip does it run the Accessibility hit test,
/// at most once every `queryInterval`, and always off the main thread.
final class DockMonitor {
    /// Main thread. `nil` means the pointer is no longer over an app icon in the Dock.
    var onHover: ((DockedApp?) -> Void)?
    /// Main thread. Called on every mouse move, so listeners must stay cheap.
    var onPointerMoved: (() -> Void)?

    private let queryInterval: TimeInterval = 0.09
    private let edgeStripWidth: CGFloat = 220

    private var eventMonitor: Any?
    private var lastQuery: TimeInterval = 0
    private var queryInFlight = false
    private var trailingCheck: DispatchWorkItem?
    private var generation = 0
    private var reportedPID: pid_t?

    func start() {
        guard eventMonitor == nil else { return }
        Debug.log("monitor started")
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.mouseMoved()
        }
    }

    func stop() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        trailingCheck?.cancel()
        trailingCheck = nil
        generation += 1
    }

    // MARK: - Mouse events

    private func mouseMoved() {
        onPointerMoved?()

        guard isInEdgeStrip(NSEvent.mouseLocation) else {
            trailingCheck?.cancel()
            trailingCheck = nil
            generation += 1                     // discard answers still on their way
            if reportedPID != nil {
                reportedPID = nil
                onHover?(nil)
            }
            return
        }
        requestQuery()
    }

    /// Debounce: queries run at most once per `queryInterval`. A throttled move schedules one
    /// trailing check, so the final resting position is always evaluated.
    private func requestQuery() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastQuery

        guard !queryInFlight, elapsed >= queryInterval else {
            guard trailingCheck == nil else { return }
            let delay = queryInFlight ? queryInterval : queryInterval - elapsed
            let work = DispatchWorkItem { [weak self] in
                self?.trailingCheck = nil
                self?.requestQuery()
            }
            trailingCheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return
        }
        startQuery()
    }

    private func startQuery() {
        let point = NSEvent.mouseLocation
        guard isInEdgeStrip(point) else { return }

        queryInFlight = true
        lastQuery = ProcessInfo.processInfo.systemUptime
        let token = generation
        let axPoint = CGPoint(x: point.x, y: primaryScreenTop - point.y)

        AccessibilityHelper.queue.async { [weak self] in
            let hit = AccessibilityHelper.dockItem(at: axPoint)
            DispatchQueue.main.async {
                self?.finishQuery(hit, token: token)
            }
        }
    }

    private func finishQuery(_ hit: DockItemHit?, token: Int) {
        queryInFlight = false
        guard token == generation else { return }

        Debug.log("hit: \(hit.map { "\($0.bundleID ?? "?") \($0.axFrame)" } ?? "nil")")
        guard let hit, let app = resolve(hit) else {
            if reportedPID != nil {
                reportedPID = nil
                onHover?(nil)
            }
            return
        }
        reportedPID = app.pid
        onHover?(app)
    }

    // MARK: - Geometry and lookup

    /// Y of the top edge of the primary screen: the origin for Accessibility coordinates.
    private var primaryScreenTop: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    private var dockEdge: DockEdge {
        let orientation = CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String
        switch orientation {
        case "left": return .left
        case "right": return .right
        default: return .bottom
        }
    }

    private func isInEdgeStrip(_ point: NSPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return false }
        let frame = screen.frame
        switch dockEdge {
        case .bottom: return point.y <= frame.minY + edgeStripWidth
        case .left:   return point.x <= frame.minX + edgeStripWidth
        case .right:  return point.x >= frame.maxX - edgeStripWidth
        }
    }

    /// Matches the Dock icon to a running process and converts its frame to Cocoa coordinates.
    private func resolve(_ hit: DockItemHit) -> DockedApp? {
        let running = NSWorkspace.shared.runningApplications.first(where: { app in
            if let bundleID = hit.bundleID, app.bundleIdentifier == bundleID { return true }
            if let url = hit.bundleURL, let appURL = app.bundleURL {
                return appURL.standardizedFileURL == url.standardizedFileURL
            }
            return false
        })
        guard let running else { return nil }

        let axFrame = hit.axFrame
        let itemFrame = CGRect(
            x: axFrame.minX,
            y: primaryScreenTop - axFrame.maxY,
            width: axFrame.width,
            height: axFrame.height
        )
        return DockedApp(
            pid: running.processIdentifier,
            name: running.localizedName ?? "",
            icon: running.icon ?? NSImage(),
            itemFrame: itemFrame,
            edge: dockEdge
        )
    }
}
