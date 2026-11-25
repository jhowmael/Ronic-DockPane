import AppKit
import SwiftUI

/// Borderless floating panel that never activates the app the user is working in.
/// It carries its own HUD background and fades/slides in and out.
final class FloatingPanel: NSPanel {
    let effectView = NSVisualEffectView()

    /// True while the fade-out runs. The panel is still visible then, but no longer takes clicks.
    private(set) var isDismissing = false
    private var animationToken = 0

    init(level: NSWindow.Level = .floating) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        self.level = level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 12
        effectView.layer?.masksToBounds = true
        effectView.layer?.borderWidth = 0.5
        effectView.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        contentView = effectView
    }

    // Lets SwiftUI rows receive clicks. Being key does not activate the app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Shows the panel at `target`. A hidden panel fades in while sliding by `slide`; a visible one glides there.
    func present(at target: NSRect, slide: CGVector = .zero) {
        animationToken += 1
        ignoresMouseEvents = false
        GenieEffect.cancelAll()

        if isVisible && !isDismissing {
            guard target != frame else { return }
            // Short and front-loaded: most of the way is covered in the first few frames, so the panel keeps
            // up with the pointer instead of trailing behind it.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduceMotion ? 0 : 0.14
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 0.84, 0.3, 1)
                animator().setFrame(target, display: true)
            }
            return
        }

        // Coming back during a fade-out continues from the current opacity, without the slide.
        let interrupted = isDismissing
        isDismissing = false
        if !interrupted {
            alphaValue = 0
            let start = reduceMotion ? target : target.offsetBy(dx: slide.dx, dy: slide.dy)
            setFrame(start, display: false)
        }
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
            animator().setFrame(target, display: true)
        }
    }

    /// Moves a visible panel smoothly, following the Dock as it grows or shrinks back.
    func move(to target: NSRect) {
        guard isVisible, !isDismissing, target != frame else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : 0.24
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
            animator().setFrame(target, display: true)
        }
    }

    /// Hides the panel at once and lets a picture of it shrink smoothly into the Dock icon.
    func dismiss(into icon: CGRect, edge: DockEdge, content: NSView) {
        guard isVisible, !isDismissing else { return }
        guard !reduceMotion,
              let image = GenieEffect.snapshot(of: content, scale: backingScaleFactor, background: true) else {
            dismiss()
            return
        }
        let source = CGRect(origin: frame.origin, size: content.bounds.size)
        animationToken += 1
        orderOut(nil)
        alphaValue = 1
        GenieEffect.play(image, from: source, into: icon, edge: edge, level: level)
    }

    /// Fades the panel out, then removes it from the screen.
    func dismiss() {
        guard isVisible, !isDismissing else { return }
        isDismissing = true
        ignoresMouseEvents = true
        animationToken += 1
        let token = animationToken
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, token == self.animationToken else { return }
            self.isDismissing = false
            self.orderOut(nil)
            self.alphaValue = 1
        })
    }
}

/// Shows the window list for the Dock icon under the pointer, and hides it once the pointer leaves both
/// the icon and the panel. The close check waits `closeDelay`, so the pointer can cross the gap.
final class FloatingPanelController {
    private let minimumWindows: Int
    private let closeDelay: TimeInterval = 0.25

    private let panel = FloatingPanel()
    private var hostingView: NSHostingView<WindowListView>?
    private var currentModel: PanelModel?

    private var shownApp: DockedApp?
    private var dockHovering = false
    /// App already checked for this hover and found with too few windows. Cleared when the pointer leaves the Dock.
    private var skippedPID: pid_t?
    private var loadingPID: pid_t?
    private var loadToken = 0
    private var previewToken = 0
    private var closeWork: DispatchWorkItem?
    /// The pointer left the Dock, which shrank back: the panel sits right above the Dock instead of above the
    /// magnified icon and its name label.
    private var isResting = false

    /// The last window list and thumbnails seen per app. Hovering an icon shows them at once and refreshes them
    /// in the background, so the panel keeps up with a pointer sweeping along the Dock.
    private var recent: [pid_t: RecentWindows] = [:]
    private var lastWarmUp: TimeInterval = 0

    private struct RecentWindows {
        var windows: [AppWindow]
        var thumbnails: [String: NSImage] = [:]
    }

    init(minimumWindows: Int) {
        self.minimumWindows = minimumWindows
    }

    /// Hides the panel right away (for example when the window switcher opens).
    func hide() {
        if panel.isVisible { hidePanel() }
    }

    // MARK: - Events from DockMonitor

    /// The pointer is over the icon of `app` in the Dock.
    func dockHovered(_ app: DockedApp) {
        if !dockHovering { warmUp() }
        dockHovering = true
        cancelCloseCheck()

        // Same app: keep the panel where it opened. Re-anchoring to the icon would make it drift
        // as the Dock's magnification grows and shrinks the icon under the moving pointer.
        if shownApp?.pid == app.pid {
            if isResting, panel.isVisible {
                isResting = false
                panel.move(to: frame(for: app, size: panel.frame.size))
            }
            return
        }
        guard app.pid != skippedPID else { return }

        // Known app: show what we saw last time right now; the fresh list replaces it if anything changed.
        if let cached = recent[app.pid], cached.windows.count >= minimumWindows {
            present(app: app, windows: cached.windows)
        }
        guard app.pid != loadingPID else { return }

        loadingPID = app.pid
        loadToken += 1
        let token = loadToken
        let pid = app.pid
        AccessibilityHelper.queue.async { [weak self] in
            let windows = AccessibilityHelper.windows(for: pid)
            DispatchQueue.main.async {
                self?.windowsLoaded(windows, for: app, token: token)
            }
        }
    }

    /// The pointer is no longer over a Dock icon.
    func dockLeft() {
        dockHovering = false
        skippedPID = nil
        if panel.isVisible { scheduleCloseCheck() }
    }

    /// Any mouse move on the system. Starts the close countdown when the pointer is away from the Dock and the panel.
    func pointerMoved() {
        guard panel.isVisible, !dockHovering else { return }
        let pointer = NSEvent.mouseLocation
        // Past the magnified icons the Dock shrinks back, so the panel comes down to meet the pointer.
        if !isResting, !panel.isDismissing, let app = shownApp, hasLeftDock(pointer, app) {
            isResting = true
            panel.move(to: restingFrame(for: app, size: panel.frame.size))
        }
        guard closeWork == nil else { return }
        if panel.frame.contains(pointer) { return }
        scheduleCloseCheck()
    }

    // MARK: - Loading and presenting

    /// Reads the windows of every app in the Dock when the pointer arrives there (at most every 5 s),
    /// so even the first hover over an icon can show its panel straight away.
    private func warmUp() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastWarmUp > 5 else { return }
        lastWarmUp = now
        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map(\.processIdentifier)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let lists = AccessibilityHelper.windows(forApps: pids)
            DispatchQueue.main.async {
                guard let self else { return }
                self.recent = self.recent.filter { lists[$0.key] != nil }
                for (pid, windows) in lists where pid != self.shownApp?.pid {
                    self.recent[pid, default: RecentWindows(windows: [])].windows = windows
                }
            }
        }
    }

    private func windowsLoaded(_ windows: [AppWindow], for app: DockedApp, token: Int) {
        recent[app.pid, default: RecentWindows(windows: [])].windows = windows
        guard token == loadToken else { return }
        loadingPID = nil
        Debug.log("windows for \(app.name): \(windows.count), hovering=\(dockHovering)")
        guard dockHovering else { return }

        if shownApp?.pid == app.pid, let model = currentModel {
            // Already on screen from the cached list: same windows keep the panel untouched.
            if model.windows.count == windows.count,
               zip(model.windows, windows).allSatisfy({ $0.title == $1.title && $0.isMinimized == $1.isMinimized }) {
                model.windows = windows
                return
            }
        }
        if windows.count >= minimumWindows {
            present(app: app, windows: windows)
        } else {
            skippedPID = app.pid
            hidePanel()
        }
    }

    private func present(app: DockedApp, windows: [AppWindow]) {
        shownApp = app
        isResting = false

        let supported = WindowPreviewProvider.isSupported
        let authorized = WindowPreviewProvider.isAuthorized
        let model = PanelModel(app: app, windows: windows, showPreviews: supported,
                               needsPermission: supported && !authorized)
        // Thumbnails from the last visit, matched by title, until fresh ones arrive.
        if let thumbnails = recent[app.pid]?.thumbnails {
            for window in windows {
                if let image = thumbnails[window.title] { model.previews[window.id] = image }
            }
        }
        let root = WindowListView(model: model, onSelect: { [weak self] window in
            self?.select(window, pid: app.pid)
        }, onEnablePreviews: { [weak self] in
            self?.hidePanel()
            WindowPreviewProvider.requestAccess()
            WindowPreviewProvider.openSettings()
        }, onClose: { [weak self] window in
            self?.close(window)
        }, onReopenApp: { [weak self] in
            self?.reopen(pid: app.pid)
        }, onQuitApp: { [weak self] in
            self?.quit(pid: app.pid)
        })
        currentModel = model

        let hosting: NSHostingView<WindowListView>
        if let existing = hostingView {
            existing.rootView = root
            hosting = existing
        } else {
            hosting = NSHostingView(rootView: root)
            panel.effectView.addSubview(hosting)
            hostingView = hosting
        }

        // The content gets its final size at once and is not laid out again while the panel glides.
        // Hidden, the panel fades in rising from the Dock; already open for another app, it glides to the new icon.
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.present(at: frame(for: app, size: size), slide: slide(for: app.edge))

        guard supported, authorized, !windows.isEmpty else { return }
        previewToken += 1
        let token = previewToken
        let requests = windows.map { PreviewRequest(key: $0.id, pid: app.pid, window: $0) }
        let titles = Dictionary(windows.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        Task { @MainActor [weak self] in
            await WindowPreviewProvider.previews(for: requests) { key, image in
                guard let self else { return }
                if let title = titles[key] { self.recent[app.pid]?.thumbnails[title] = image }
                guard token == self.previewToken, self.shownApp?.pid == app.pid else { return }
                model.previews[key] = image
            }
        }
    }

    /// Closes the real window and sucks its card into the Dock icon. After the last one the panel shows the
    /// app card, since most Mac apps keep running with no windows.
    private func close(_ window: AppWindow) {
        AccessibilityHelper.queue.async { AccessibilityHelper.close(window) }
        guard let model = currentModel, let app = shownApp, let hosting = hostingView else { return }

        if let card = model.cardFrames[window.id], !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
           let image = GenieEffect.snapshot(of: hosting, scale: panel.backingScaleFactor, background: false),
           let piece = image.cropping(to: CGRect(x: card.minX * panel.backingScaleFactor,
                                                 y: card.minY * panel.backingScaleFactor,
                                                 width: card.width * panel.backingScaleFactor,
                                                 height: card.height * panel.backingScaleFactor)) {
            // SwiftUI frames start at the top-left; the screen starts at the bottom-left.
            let origin = panel.frame.origin
            let source = CGRect(x: origin.x + card.minX, y: origin.y + hosting.frame.height - card.maxY,
                                width: card.width, height: card.height)
            GenieEffect.play(piece, from: source, into: iconTarget(for: app), edge: app.edge, level: panel.level)
        }

        model.windows.removeAll { $0.id == window.id }
        model.previews[window.id] = nil
        recent[app.pid]?.windows.removeAll { $0.title == window.title }
        hosting.rootView = hosting.rootView
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.present(at: isResting ? restingFrame(for: app, size: size) : frame(for: app, size: size))
    }

    /// Asks a running app with no windows to open one, like clicking its Dock icon (the "reopen" event).
    private func reopen(pid: pid_t) {
        hidePanel()
        guard let url = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// Quits the app (it may still ask to save documents).
    private func quit(pid: pid_t) {
        hidePanel()
        NSRunningApplication(processIdentifier: pid)?.terminate()
    }

    private func select(_ window: AppWindow, pid: pid_t) {
        AccessibilityHelper.queue.async {
            AccessibilityHelper.raise(window, pid: pid)
        }
        hidePanel()
    }

    /// `intoDock` plays the genie effect into the app's icon (the pointer simply left); otherwise it fades out.
    private func hidePanel(intoDock: Bool = false) {
        Debug.log("hide panel")
        cancelCloseCheck()
        if intoDock, let app = shownApp, let hosting = hostingView {
            panel.dismiss(into: iconTarget(for: app), edge: app.edge, content: hosting)
        } else {
            panel.dismiss()
        }
        shownApp = nil
        isResting = false
        loadingPID = nil
        loadToken += 1
        previewToken += 1
    }

    // MARK: - Closing

    private func scheduleCloseCheck() {
        guard closeWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.closeWork = nil
            if self.panel.frame.contains(NSEvent.mouseLocation) || self.dockHovering { return }
            self.hidePanel(intoDock: true)
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + closeDelay, execute: work)
    }

    private func cancelCloseCheck() {
        closeWork?.cancel()
        closeWork = nil
    }

    // MARK: - Positioning

    /// The fade-in starts a few points closer to the Dock, so the panel rises out of it.
    private func slide(for edge: DockEdge) -> CGVector {
        switch edge {
        case .bottom: return CGVector(dx: 0, dy: -8)
        case .left: return CGVector(dx: -8, dy: 0)
        case .right: return CGVector(dx: 8, dy: 0)
        }
    }

    private func screen(for app: DockedApp) -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.intersects(app.itemFrame) }) ?? NSScreen.main
    }

    /// Whether the pointer has gone past the (fully magnified) icons, away from the screen edge.
    private func hasLeftDock(_ pointer: CGPoint, _ app: DockedApp) -> Bool {
        let reach = reach(of: app)
        switch app.edge {
        case .bottom: return pointer.y > reach.maxY
        case .left: return pointer.x > reach.maxX
        case .right: return pointer.x < reach.minX
        }
    }

    /// Same place along the Dock, but right above the Dock at its normal size (its edge is where the
    /// screen's visible area ends).
    private func restingFrame(for app: DockedApp, size: CGSize) -> NSRect {
        var frame = self.frame(for: app, size: size)
        guard let visible = screen(for: app)?.visibleFrame else { return frame }
        let gap: CGFloat = 10
        switch app.edge {
        case .bottom: frame.origin.y = min(frame.origin.y, visible.minY + gap)
        case .left: frame.origin.x = min(frame.origin.x, visible.minX + gap)
        case .right: frame.origin.x = max(frame.origin.x, visible.maxX - gap - size.width)
        }
        return frame
    }

    /// Where the close animation goes: the icon as it is now. Once the Dock has shrunk back, that is a
    /// normal-size icon centred in the Dock, not the magnified frame seen on hover.
    private func iconTarget(for app: DockedApp) -> CGRect {
        let icon = app.itemFrame
        guard isResting, let screen = screen(for: app) else { return icon }
        let full = screen.frame
        let visible = screen.visibleFrame
        switch app.edge {
        case .bottom:
            let thickness = visible.minY - full.minY
            guard thickness > 20 else { return icon }
            let side = thickness * 0.72
            return CGRect(x: icon.midX - side / 2, y: full.minY + (thickness - side) / 2, width: side, height: side)
        case .left:
            let thickness = visible.minX - full.minX
            guard thickness > 20 else { return icon }
            let side = thickness * 0.72
            return CGRect(x: full.minX + (thickness - side) / 2, y: icon.midY - side / 2, width: side, height: side)
        case .right:
            let thickness = full.maxX - visible.maxX
            guard thickness > 20 else { return icon }
            let side = thickness * 0.72
            return CGRect(x: visible.maxX + (thickness - side) / 2, y: icon.midY - side / 2, width: side, height: side)
        }
    }

    /// The icon's frame at full Dock magnification. The icon under the pointer may still be growing when the
    /// panel opens; measured from its current size, the panel would end up sitting on it.
    private func reach(of app: DockedApp) -> CGRect {
        let icon = app.itemFrame
        guard (CFPreferencesCopyAppValue("magnification" as CFString, "com.apple.dock" as CFString) as? Bool) == true,
              let large = CFPreferencesCopyAppValue("largesize" as CFString, "com.apple.dock" as CFString) as? NSNumber
        else { return icon }
        // The Dock's item frame is the icon plus a strip for the running indicator, on the screen-edge side.
        let maxIcon = CGFloat(large.doubleValue) * 1.05
        switch app.edge {
        case .bottom:
            let height = icon.height - icon.width + max(icon.width, maxIcon)
            return CGRect(x: icon.minX, y: icon.minY, width: icon.width, height: max(icon.height, height))
        case .left:
            let width = icon.width - icon.height + max(icon.height, maxIcon)
            return CGRect(x: icon.minX, y: icon.minY, width: max(icon.width, width), height: icon.height)
        case .right:
            let width = max(icon.width, icon.width - icon.height + max(icon.height, maxIcon))
            return CGRect(x: icon.maxX - width, y: icon.minY, width: width, height: icon.height)
        }
    }

    /// Places the panel just outside the icon, on the side facing the screen centre, and keeps it on screen.
    private func frame(for app: DockedApp, size: CGSize) -> NSRect {
        let icon = reach(of: app)
        // Above a bottom Dock, the app-name label the Dock draws over the icon fits entirely between the
        // icon and the panel, so it never overlaps the panel's edge.
        let gap: CGFloat = app.edge == .bottom ? 34 : 10
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(icon) }) ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? icon

        var origin: CGPoint
        switch app.edge {
        case .bottom:
            origin = CGPoint(x: icon.midX - size.width / 2, y: icon.maxY + gap)
        case .left:
            origin = CGPoint(x: icon.maxX + gap, y: icon.midY - size.height / 2)
        case .right:
            origin = CGPoint(x: icon.minX - gap - size.width, y: icon.midY - size.height / 2)
        }

        origin.x = (min(max(origin.x, bounds.minX + 8), bounds.maxX - size.width - 8)).rounded()
        origin.y = (min(max(origin.y, bounds.minY), bounds.maxY - size.height - 8)).rounded()
        return NSRect(origin: origin, size: size)
    }
}
