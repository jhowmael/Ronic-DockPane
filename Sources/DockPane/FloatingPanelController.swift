import AppKit
import SwiftUI

/// Borderless floating panel that never activates the app the user is working in.
final class FloatingPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    // Lets SwiftUI rows receive clicks. Being key does not activate the app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Shows the window list for the Dock icon under the pointer, and hides it once the pointer leaves both
/// the icon and the panel. The close check waits `closeDelay`, so the pointer can cross the gap.
final class FloatingPanelController {
    private let minimumWindows: Int
    private let closeDelay: TimeInterval = 0.25

    private let panel = FloatingPanel()
    private let effectView = NSVisualEffectView()
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

    init(minimumWindows: Int) {
        self.minimumWindows = minimumWindows

        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 12
        effectView.layer?.masksToBounds = true
        effectView.layer?.borderWidth = 0.5
        effectView.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        panel.contentView = effectView
    }

    // MARK: - Events from DockMonitor

    /// The pointer is over the icon of `app` in the Dock.
    func dockHovered(_ app: DockedApp) {
        dockHovering = true
        cancelCloseCheck()

        if shownApp?.pid == app.pid {
            shownApp = app
            reposition(app)
            return
        }
        guard app.pid != skippedPID, app.pid != loadingPID else { return }

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
        guard panel.isVisible, closeWork == nil, !dockHovering else { return }
        if panel.frame.contains(NSEvent.mouseLocation) { return }
        scheduleCloseCheck()
    }

    // MARK: - Loading and presenting

    private func windowsLoaded(_ windows: [AppWindow], for app: DockedApp, token: Int) {
        guard token == loadToken else { return }
        loadingPID = nil
        Debug.log("windows for \(app.name): \(windows.count), hovering=\(dockHovering)")
        guard dockHovering else { return }

        if windows.count >= minimumWindows {
            present(app: app, windows: windows)
        } else {
            skippedPID = app.pid
            hidePanel()
        }
    }

    private func present(app: DockedApp, windows: [AppWindow]) {
        shownApp = app

        let supported = WindowPreviewProvider.isSupported
        let authorized = WindowPreviewProvider.isAuthorized
        let model = PanelModel(app: app, windows: windows, showPreviews: supported,
                               needsPermission: supported && !authorized)
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
            hosting.autoresizingMask = [.width, .height]
            effectView.addSubview(hosting)
            hostingView = hosting
        }

        // The panel opens right away with placeholders of the final size; thumbnails fill in when captured.
        let size = hosting.fittingSize
        panel.setContentSize(size)
        reposition(app)
        panel.orderFrontRegardless()

        guard supported, authorized, !windows.isEmpty else { return }
        previewToken += 1
        let token = previewToken
        Task { @MainActor [weak self] in
            let previews = await WindowPreviewProvider.previews(for: windows, pid: app.pid)
            guard let self, token == self.previewToken, self.shownApp?.pid == app.pid else { return }
            Debug.log("previews: \(previews.count)/\(windows.count)")
            model.previews = previews
        }
    }

    /// Closes the real window and removes its card. After the last one the panel shows the app card,
    /// since most Mac apps keep running with no windows.
    private func close(_ window: AppWindow) {
        AccessibilityHelper.queue.async { AccessibilityHelper.close(window) }
        guard let model = currentModel, let app = shownApp, let hosting = hostingView else { return }
        model.windows.removeAll { $0.id == window.id }
        model.previews[window.id] = nil
        hosting.rootView = hosting.rootView
        hosting.layoutSubtreeIfNeeded()
        panel.setContentSize(hosting.fittingSize)
        reposition(app)
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

    private func hidePanel() {
        Debug.log("hide panel")
        cancelCloseCheck()
        panel.orderOut(nil)
        shownApp = nil
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
            self.hidePanel()
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + closeDelay, execute: work)
    }

    private func cancelCloseCheck() {
        closeWork?.cancel()
        closeWork = nil
    }

    // MARK: - Positioning

    private func reposition(_ app: DockedApp) {
        let size = panel.frame.size
        panel.setFrame(frame(for: app, size: size), display: true)
    }

    /// Places the panel just outside the icon, on the side facing the screen centre, and keeps it on screen.
    private func frame(for app: DockedApp, size: CGSize) -> NSRect {
        let icon = app.itemFrame
        // Above a bottom Dock, leave room for the app-name label the Dock shows over the icon.
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

        origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - size.width - 8)
        origin.y = min(max(origin.y, bounds.minY), bounds.maxY - size.height - 8)
        return NSRect(origin: origin, size: size)
    }
}
