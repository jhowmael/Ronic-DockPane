import AppKit
import SwiftUI
import CoreGraphics

/// One window in the switcher, with the app it belongs to.
struct SwitcherItem: Identifiable {
    let id: Int
    let pid: pid_t
    let appName: String
    let icon: NSImage
    let window: AppWindow
}

// MARK: - Listing the windows

enum SwitcherWindows {
    struct AppInfo {
        let pid: pid_t
        let name: String
        let icon: NSImage
    }

    /// Running apps that have a Dock icon. Call on the main thread.
    static func regularApps() -> [AppInfo] {
        let own = ProcessInfo.processInfo.processIdentifier
        let fallbackIcon = NSImage(named: NSImage.applicationIconName) ?? NSImage()
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, app.processIdentifier != own, !app.isTerminated else { return nil }
            return AppInfo(pid: app.processIdentifier, name: app.localizedName ?? "App", icon: app.icon ?? fallbackIcon)
        }
    }

    /// Every window of `apps`, the most recently used first. The on-screen stacking order is the usage order;
    /// minimized windows and windows of hidden apps come last. Runs on the Accessibility queue.
    static func load(_ apps: [AppInfo]) -> [SwitcherItem] {
        let lists = AccessibilityHelper.windows(forApps: apps.map(\.pid))

        // Front-to-back list of normal windows on screen. Bounds and owner need no permission (titles would).
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var stack: [(pid: pid_t, frame: CGRect)] = []
        for entry in info {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            stack.append((pid, frame))
        }

        var taken = Set<Int>()
        var ranked: [(rank: Int, appRank: Int, order: Int, app: AppInfo, window: AppWindow)] = []
        for (appIndex, app) in apps.enumerated() {
            let appRank = stack.firstIndex { $0.pid == app.pid } ?? stack.count + appIndex
            for window in lists[app.pid] ?? [] {
                // AX and CoreGraphics both use top-left global coordinates, so equal frames mean the same window.
                var rank = Int.max
                if !window.isMinimized, let frame = window.frame,
                   let index = stack.indices.first(where: {
                       !taken.contains($0) && stack[$0].pid == app.pid && isSameFrame(stack[$0].frame, frame)
                   }) {
                    rank = index
                    taken.insert(index)
                }
                ranked.append((rank, appRank, ranked.count, app, window))
            }
        }
        ranked.sort { ($0.rank, $0.appRank, $0.order) < ($1.rank, $1.appRank, $1.order) }

        return ranked.enumerated().map { index, entry in
            SwitcherItem(id: index, pid: entry.app.pid, appName: entry.app.name, icon: entry.app.icon, window: entry.window)
        }
    }

    private static func isSameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }
}

// MARK: - Keyboard

/// Watches the keyboard for ⌥Tab with a CGEventTap. While the switcher is open it swallows the keys, so they never
/// reach the app behind it. Every other key passes through untouched, and no key is ever stored or logged.
final class SwitcherHotKey {
    enum Command {
        case next, previous, left, right, up, down, commit, cancel, released
    }

    private enum Key {
        static let tab: Int64 = 48
        static let returnKey: Int64 = 36
        static let enter: Int64 = 76
        static let escape: Int64 = 53
        static let left: Int64 = 123
        static let right: Int64 = 124
        static let down: Int64 = 125
        static let up: Int64 = 126
    }

    /// The key pressed with ⌥: Tab by default. `defaults write io.github.jhowmael.ronicdockpane switcherKeyCode -int 50`
    /// picks another one (50 is the key left of 1) if another app needs ⌥Tab.
    private let triggerKey: Int64 = {
        let code = UserDefaults.standard.integer(forKey: "switcherKeyCode")
        return code > 0 ? Int64(code) : Key.tab
    }()

    /// ⌘Tab opens the window switcher too, instead of the macOS app switcher.
    var handlesCommandTab = true
    /// The modifier that opened the current switch (⌥ or ⌘). Letting go of it switches.
    private(set) var sessionModifier: CGEventFlags = .maskAlternate

    /// Asked on every key event, on the main thread.
    var isActive: () -> Bool = { false }
    var onCommand: (Command) -> Void = { _ in }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isInstalled: Bool { tap != nil }

    /// Fails without the Accessibility permission.
    func install() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            // The HID level is where events enter the window server, before system shortcuts such as ⌘Tab
            // are handled; a session tap would see ⌘Tab only after the app switcher had opened.
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: switcherTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func uninstall() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass

        case .flagsChanged:
            if isActive() && !event.flags.contains(sessionModifier) { onCommand(.released) }
            return pass

        case .keyDown, .keyUp:
            let flags = event.flags
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            let active = isActive()

            if type == .keyDown, key == triggerKey, !flags.contains(.maskControl) {
                let option = flags.contains(.maskAlternate)
                let command = flags.contains(.maskCommand)
                let opens: CGEventFlags? = option && !command ? .maskAlternate
                    : command && !option && handlesCommandTab ? .maskCommand : nil
                if let opens, !active || opens == sessionModifier {
                    if !active { sessionModifier = opens }
                    onCommand(flags.contains(.maskShift) ? .previous : .next)
                    return nil
                }
            }
            guard active else { return pass }

            // The modifier was let go without us seeing it (secure input, for example): finish, let the key through.
            if !flags.contains(sessionModifier) {
                onCommand(.released)
                return pass
            }
            if type == .keyDown {
                switch key {
                case Key.escape: onCommand(.cancel)
                case Key.returnKey, Key.enter: onCommand(.commit)
                case Key.left: onCommand(.left)
                case Key.right: onCommand(.right)
                case Key.up: onCommand(.up)
                case Key.down: onCommand(.down)
                default: break
                }
            }
            return nil

        default:
            return pass
        }
    }
}

private func switcherTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<SwitcherHotKey>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
}

// MARK: - Sharing ⌥Tab with Ronic MacToWindows

/// Ronic MacToWindows has its own Alt+Tab, for apps, and its keyboard tap sees ⌥Tab first. This tells it, with a
/// distributed notification, whether ⌥Tab currently belongs to this switcher, so it lets the key through.
///
/// * `io.github.jhowmael.ronicdockpane.switcher`, object `"on"` or `"off"`: posted when the switcher starts
///   listening and when it stops (menu toggle, quitting).
/// * `io.github.jhowmael.ronicdockpane.switcher.query`: another app asks; the current state is posted again.
final class SwitcherAnnouncer: NSObject {
    static let stateName = Notification.Name("io.github.jhowmael.ronicdockpane.switcher")
    static let queryName = Notification.Name("io.github.jhowmael.ronicdockpane.switcher.query")

    private var isOn = false

    override init() {
        super.init()
        // Menu bar apps are never active, so delivery must not wait for activation.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(queried), name: Self.queryName, object: nil, suspensionBehavior: .deliverImmediately
        )
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func announce(_ on: Bool) {
        isOn = on
        post()
    }

    @objc private func queried() {
        post()
    }

    private func post() {
        Debug.log("switcher: announce \(isOn ? "on" : "off")")
        DistributedNotificationCenter.default().postNotificationName(
            Self.stateName, object: isOn ? "on" : "off", userInfo: nil, deliverImmediately: true
        )
    }
}

// MARK: - Controller

/// ⌥Tab window switcher: every window of every app as a card, the most recent first, like the Windows Alt+Tab.
/// Keep ⌥ held and press Tab (⇧Tab backwards, or the arrow keys) to move; let go of ⌥ to switch.
/// Esc cancels. A quick ⌥Tab tap switches to the previous window without showing the panel.
final class WindowSwitcher {
    private enum Phase {
        case idle, loading, ready, shown
    }

    /// A quick tap switches without the panel flashing on screen.
    private let showDelay: TimeInterval = 0.12
    private let maxColumns = 6
    private let maxRows = 4

    private let panel = FloatingPanel()
    private let hotKey = SwitcherHotKey()
    private let announcer = SwitcherAnnouncer()
    private var hosting: NSHostingView<SwitcherView>?
    private var model: SwitcherModel?
    private var screen: NSScreen?

    private var phase = Phase.idle
    /// Tab presses seen while the windows were still loading.
    private var steps = 0
    private var released = false
    private var token = 0
    private var showDeadline = Date()
    private var pointerAtOpen = CGPoint.zero
    private var watchdog: Timer?
    private var retryTimer: Timer?
    private var wanted = false

    /// Called when a switch begins, so the Dock panel steps aside.
    var onBegin: () -> Void = {}

    /// ⌘Tab opens the window switcher too (on by default); off leaves ⌘Tab to macOS.
    var handlesCommandTab: Bool {
        get { hotKey.handlesCommandTab }
        set { hotKey.handlesCommandTab = newValue }
    }

    /// Follows the pointer while the panel is open. SwiftUI hover events reach a panel of a background app late,
    /// or not at all while the pointer stays inside one card, so the pointer is read directly at 60 Hz.
    private var pointerTimer: Timer?
    private var lastPointer = CGPoint.zero
    private var pointerMoved = false

    var isActive: Bool { phase != .idle }

    init() {
        hotKey.isActive = { [weak self] in self?.isActive ?? false }
        hotKey.onCommand = { [weak self] command in self?.handle(command) }
    }

    // MARK: Turning it on and off

    func start() {
        wanted = true
        if hotKey.install() {
            Debug.log("switcher: ⌥Tab ready")
            announcer.announce(true)
            retryTimer?.invalidate()
            retryTimer = nil
            return
        }
        // Without Accessibility the tap cannot be created yet; try again until the permission is granted.
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, self.wanted, self.hotKey.install() else { return }
            Debug.log("switcher: ⌥Tab ready")
            self.announcer.announce(true)
            self.retryTimer?.invalidate()
            self.retryTimer = nil
        }
    }

    func stop() {
        wanted = false
        retryTimer?.invalidate()
        retryTimer = nil
        cancel()
        hotKey.uninstall()
        announcer.announce(false)
    }

    // MARK: Commands

    private func handle(_ command: SwitcherHotKey.Command) {
        switch command {
        case .next, .previous:
            let delta = command == .next ? 1 : -1
            if phase == .idle { begin(delta) } else { move(by: delta) }
        case .left: move(by: -1)
        case .right: move(by: 1)
        case .up: moveRow(by: -1)
        case .down: moveRow(by: 1)
        case .commit, .released: finish()
        case .cancel: cancel()
        }
    }

    private func begin(_ delta: Int) {
        phase = .loading
        steps = delta
        released = false
        token += 1
        let token = self.token
        showDeadline = Date().addingTimeInterval(showDelay)
        onBegin()
        startWatchdog()

        let apps = SwitcherWindows.regularApps()
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        AccessibilityHelper.queue.async { [weak self] in
            let items = SwitcherWindows.load(apps)
            DispatchQueue.main.async {
                self?.loaded(items, frontPID: frontPID, token: token)
            }
        }
    }

    private func loaded(_ items: [SwitcherItem], frontPID: pid_t?, token: Int) {
        guard token == self.token, phase == .loading else { return }
        guard !items.isEmpty else {
            Debug.log("switcher: no windows")
            end()
            return
        }

        let screen = screenUnderPointer()
        let fit = capacity(in: screen.visibleFrame)
        let visible = Array(items.prefix(fit.columns * fit.rows))

        // Like ⌘Tab: the first card is the current window, so one Tab goes to the previous one. When the
        // frontmost app has no window (the desktop, say), the first card is already "previous".
        let startsAtCurrent = visible.first?.pid == frontPID
        let offset = (startsAtCurrent || steps < 0) ? steps : steps - 1
        let selection = ((offset % visible.count) + visible.count) % visible.count

        let model = SwitcherModel(items: visible, selection: selection,
                                  maxColumns: fit.columns, hiddenCount: items.count - visible.count)
        self.model = model
        self.screen = screen
        Debug.log("switcher: \(items.count) windows, selection \(selection)")
        loadPreviews(for: model, token: token)

        if released {
            finish()
            return
        }
        phase = .ready
        let wait = max(0, showDeadline.timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, token == self.token, self.phase == .ready else { return }
            self.show()
        }
    }

    private func show() {
        guard let model else { return }
        let root = SwitcherView(model: model, onSelect: { [weak self] index in
            self?.model?.selection = index
            self?.finish()
        }, onClose: { [weak self] index in
            self?.closeWindow(at: index)
        })

        let hosting: NSHostingView<SwitcherView>
        if let existing = self.hosting {
            existing.rootView = root
            hosting = existing
        } else {
            hosting = NSHostingView(rootView: root)
            panel.effectView.addSubview(hosting)
            self.hosting = hosting
        }

        phase = .shown
        pointerAtOpen = NSEvent.mouseLocation
        lastPointer = pointerAtOpen
        pointerMoved = false
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.present(at: centeredFrame(size: size))

        pointerTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.trackPointer() }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    /// The card under the pointer gets the selection and its ✕, once the pointer has moved since the panel
    /// opened (a pointer resting where the panel appears changes nothing).
    private func trackPointer() {
        guard phase == .shown, let model, let hosting else { return }
        let pointer = NSEvent.mouseLocation
        guard pointer != lastPointer else { return }
        lastPointer = pointer
        if !pointerMoved {
            guard hypot(pointer.x - pointerAtOpen.x, pointer.y - pointerAtOpen.y) > 2 else { return }
            pointerMoved = true
        }

        // Card frames are reported by SwiftUI from the top-left of the content; the screen starts bottom-left.
        let origin = panel.frame.origin
        let height = hosting.frame.height
        let hit = model.items.indices.first { index in
            guard let card = model.cardFrames[model.items[index].id] else { return false }
            let rect = CGRect(x: origin.x + card.minX, y: origin.y + height - card.maxY,
                              width: card.width, height: card.height)
            return rect.contains(pointer)
        }
        if model.pointerIndex != hit { model.pointerIndex = hit }
        if let hit, model.selection != hit { model.selection = hit }
    }

    private func loadPreviews(for model: SwitcherModel, token: Int) {
        guard WindowPreviewProvider.isSupported, WindowPreviewProvider.isAuthorized else { return }
        let requests = model.items.map { PreviewRequest(key: $0.id, pid: $0.pid, window: $0.window) }
        Task { @MainActor [weak self, weak model] in
            await WindowPreviewProvider.previews(for: requests) { key, image in
                guard let self, let model, token == self.token else { return }
                model.previews[key] = image
            }
        }
    }

    private func move(by delta: Int) {
        if phase == .loading {
            steps += delta
            return
        }
        guard let model, !model.items.isEmpty else { return }
        let count = model.items.count
        model.selection = ((model.selection + delta) % count + count) % count
    }

    private func moveRow(by delta: Int) {
        guard phase == .shown, let model else { return }
        let target = model.selection + delta * model.columns
        if model.items.indices.contains(target) { model.selection = target }
    }

    /// Switches to the selected window.
    private func finish() {
        switch phase {
        case .idle:
            return
        case .loading:
            released = true
            return
        case .ready, .shown:
            break
        }
        guard let model, model.items.indices.contains(model.selection) else {
            end()
            return
        }
        let item = model.items[model.selection]
        Debug.log("switcher: switch to \(item.appName) (card \(model.selection))")
        end()
        AccessibilityHelper.queue.async {
            AccessibilityHelper.raise(item.window, pid: item.pid)
        }
    }

    private func cancel() {
        guard phase != .idle else { return }
        Debug.log("switcher: cancelled")
        end()
    }

    private func end() {
        phase = .idle
        token += 1
        watchdog?.invalidate()
        watchdog = nil
        pointerTimer?.invalidate()
        pointerTimer = nil
        model = nil
        panel.dismiss()
    }

    /// Closes the real window and removes its card, like the ✕ in the Dock panel.
    private func closeWindow(at index: Int) {
        guard phase == .shown, let model, model.items.indices.contains(index), let hosting else { return }
        let item = model.items.remove(at: index)
        model.previews[item.id] = nil
        AccessibilityHelper.queue.async { AccessibilityHelper.close(item.window) }

        if model.items.isEmpty {
            end()
            return
        }
        if index < model.selection || model.selection >= model.items.count {
            model.selection = max(0, model.selection - 1)
        }
        hosting.rootView = hosting.rootView
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.present(at: centeredFrame(size: size))
    }

    /// A missed key-up (secure input, a tap timeout) must never leave the switcher open and swallowing keys.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.isActive else { return }
            if !CGEventSource.flagsState(.combinedSessionState).contains(self.hotKey.sessionModifier) {
                self.finish()
            }
        }
    }

    // MARK: Layout

    private func screenUnderPointer() -> NSScreen {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// How many cards fit on the screen: up to six columns and four rows.
    private func capacity(in bounds: NSRect) -> (columns: Int, rows: Int) {
        let card = SwitcherView.cardSize
        let columns = Int((bounds.width * 0.92 - 16 + SwitcherView.spacing) / (card.width + SwitcherView.spacing))
        let rows = Int((bounds.height * 0.85 - 60 + SwitcherView.spacing) / (card.height + SwitcherView.spacing))
        return (min(max(columns, 1), maxColumns), min(max(rows, 1), maxRows))
    }

    private func centeredFrame(size: CGSize) -> NSRect {
        let bounds = (screen ?? screenUnderPointer()).visibleFrame
        return NSRect(x: (bounds.midX - size.width / 2).rounded(), y: (bounds.midY - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }
}

// MARK: - View

final class SwitcherModel: ObservableObject {
    @Published var items: [SwitcherItem]
    @Published var selection: Int
    /// Thumbnails keyed by `SwitcherItem.id`.
    @Published var previews: [Int: NSImage] = [:]
    /// The card under the pointer, which shows its ✕.
    @Published var pointerIndex: Int?
    /// Where each card is drawn (top-left origin, in the panel), keyed by `SwitcherItem.id`. Not published.
    var cardFrames: [Int: CGRect] = [:]
    let maxColumns: Int
    /// Windows that did not fit on the screen.
    let hiddenCount: Int

    var columns: Int { max(1, min(items.count, maxColumns)) }

    init(items: [SwitcherItem], selection: Int, maxColumns: Int, hiddenCount: Int) {
        self.items = items
        self.selection = selection
        self.maxColumns = maxColumns
        self.hiddenCount = hiddenCount
    }
}

/// The switcher's cards in rows, with the selected window's app and title underneath.
struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel
    let onSelect: (Int) -> Void
    let onClose: (Int) -> Void

    static let spacing: CGFloat = 4
    /// A `PreviewCard`: the thumbnail plus its padding and title row.
    static var cardSize: CGSize {
        let thumb = WindowPreviewProvider.thumbnailSize
        return CGSize(width: thumb.width + 12, height: thumb.height + 41)
    }

    private var gridWidth: CGFloat {
        CGFloat(model.columns) * Self.cardSize.width + CGFloat(model.columns - 1) * Self.spacing
    }

    private var rows: [[Int]] {
        let columns = model.columns
        return stride(from: 0, to: model.items.count, by: columns).map {
            Array($0..<min($0 + columns, model.items.count))
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            VStack(alignment: .leading, spacing: Self.spacing) {
                ForEach(rows, id: \.self) { row in
                    HStack(alignment: .top, spacing: Self.spacing) {
                        ForEach(row, id: \.self) { index in
                            card(at: index)
                        }
                    }
                }
            }
            footer
        }
        .padding(5)
        .coordinateSpace(name: CardFramesKey.space)
        .onPreferenceChange(CardFramesKey.self) { frames in model.cardFrames = frames }
    }

    private func card(at index: Int) -> some View {
        let item = model.items[index]
        return PreviewCard(window: item.window, icon: item.icon, image: model.previews[item.id],
                           onSelect: { _ in onSelect(index) }, onClose: { _ in onClose(index) },
                           isSelected: index == model.selection, pointerOver: model.pointerIndex == index,
                           frameKey: item.id)
            .id(item.id)
    }

    private var footer: some View {
        let item = model.items.indices.contains(model.selection) ? model.items[model.selection] : nil
        return HStack(spacing: 6) {
            Text(item?.appName ?? "")
                .font(.system(size: 13, weight: .semibold))
                .layoutPriority(1)
            Text(item?.window.title ?? "")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if model.hiddenCount > 0 {
                Text("+\(model.hiddenCount) janelas")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 6)
        .frame(width: gridWidth)
        .padding(.bottom, 2)
    }
}
