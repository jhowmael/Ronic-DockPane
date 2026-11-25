import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

@main
struct DockPaneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: appDelegate.state,
                        onGrant: appDelegate.showPermissionAlert,
                        onGrantScreen: appDelegate.showScreenRecordingAlert)
        } label: {
            Image(nsImage: MenuBarIcon.image)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// The Ronic "R" with the little Dock bar from the logo, as a monochrome template for the menu bar.
enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let base = NSFont.systemFont(ofSize: 15, weight: .black)
            let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 15) } ?? base
            let letter = NSAttributedString(string: "R", attributes: [.font: font, .foregroundColor: NSColor.black])
            letter.draw(at: NSPoint(x: 0.5, y: (18 - letter.size().height) / 2 + 0.5))
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 11.8, y: 2.6, width: 5.8, height: 2.6), xRadius: 1.3, yRadius: 1.3).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Ronic DockPane"
        return image
    }()
}

/// Menu bar menu: permission status, launch at login, quit.
private struct MenuContent: View {
    @ObservedObject var state: AppState
    let onGrant: () -> Void
    let onGrantScreen: () -> Void

    var body: some View {
        Text(state.isTrusted ? "Acessibilidade: concedida" : "Acessibilidade: não concedida")

        if !state.isTrusted {
            Button("Conceder permissão…", action: onGrant)
        }

        if WindowPreviewProvider.isSupported {
            Text(state.hasScreenAccess ? "Prévias das janelas: ativas" : "Prévias das janelas: sem permissão")
            if !state.hasScreenAccess {
                Button("Ativar prévias (Gravação de Tela)…", action: onGrantScreen)
                Button("Já ativei: reabrir o app", action: AppRelauncher.relaunch)
            }
        }

        Divider()

        Toggle("Alternador de janelas (⌥Tab)", isOn: Binding(
            get: { state.switcherEnabled },
            set: { state.setSwitcherEnabled($0) }
        ))
        Toggle("Iniciar com o macOS", isOn: Binding(
            get: { state.launchAtLogin },
            set: { state.setLaunchAtLogin($0) }
        ))

        Divider()

        Button("Sair") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

final class AppState: ObservableObject {
    @Published private(set) var isTrusted = AccessibilityHelper.isTrusted
    @Published private(set) var hasScreenAccess = WindowPreviewProvider.isAuthorized
    @Published private(set) var launchAtLogin = LaunchAtLogin.isEnabled
    @Published private(set) var switcherEnabled = UserDefaults.standard.object(forKey: AppState.switcherKey) as? Bool ?? true
    /// Set by the app delegate to turn the ⌥Tab switcher on and off.
    var onSwitcherChange: (Bool) -> Void = { _ in }

    private static let switcherKey = "switcherEnabled"

    func setSwitcherEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: AppState.switcherKey)
        switcherEnabled = enabled
        onSwitcherChange(enabled)
    }

    func refresh() {
        isTrusted = AccessibilityHelper.isTrusted
        hasScreenAccess = WindowPreviewProvider.isAuthorized
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.set(enabled)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Não foi possível alterar a inicialização"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        launchAtLogin = LaunchAtLogin.isEnabled
    }
}

/// The system only applies a new Screen Recording permission to processes started afterwards.
enum AppRelauncher {
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$1\"", "sh", path]
        try? process.run()
        NSApp.terminate(nil)
    }
}

/// Start at login through the system's login-items list (macOS 13+).
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()

    private let dockMonitor = DockMonitor()
    /// Panels with fewer windows than this are not shown. Change here to adjust the threshold.
    private let panel = FloatingPanelController(minimumWindows: 0)
    private let switcher = WindowSwitcher()
    private var activationObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon and no app menu.
        NSApp.setActivationPolicy(.accessory)

        let environment = ProcessInfo.processInfo.environment
        if environment["DOCKPANE_SHOT"] != nil || environment["DOCKPANE_SHOT_SWITCHER"] != nil {
            if let path = environment["DOCKPANE_SHOT"] { DemoScreenshot.write(to: path) }
            if let path = environment["DOCKPANE_SHOT_SWITCHER"] { DemoScreenshot.writeSwitcher(to: path) }
            NSApp.terminate(nil)
            return
        }

        dockMonitor.onHover = { [weak self] app in
            guard let self, !self.switcher.isActive else { return }
            if let app {
                self.panel.dockHovered(app)
            } else {
                self.panel.dockLeft()
            }
        }
        dockMonitor.onPointerMoved = { [weak self] in
            self?.panel.pointerMoved()
        }

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.state.refresh()
            self?.startMonitoringIfTrusted()
        }

        switcher.onBegin = { [weak self] in self?.panel.hide() }
        state.onSwitcherChange = { [weak self] enabled in
            if enabled { self?.switcher.start() } else { self?.switcher.stop() }
        }
        // Waits for the Accessibility permission on its own if it is not granted yet.
        if state.switcherEnabled { switcher.start() }

        startMonitoringIfTrusted()
        if !state.isTrusted {
            showPermissionAlert()
        } else {
            askForScreenRecordingOnce()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        dockMonitor.stop()
        switcher.stop()
    }

    private func startMonitoringIfTrusted() {
        if AccessibilityHelper.isTrusted {
            dockMonitor.start()
        } else {
            dockMonitor.stop()
        }
    }

    func showPermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Ronic DockPane precisa da permissão de Acessibilidade"
        alert.informativeText = """
        Para ler os ícones do Dock e a lista de janelas, o Ronic DockPane precisa de acesso de Acessibilidade.

        Em Ajustes do Sistema › Privacidade e Segurança › Acessibilidade, ative o Ronic DockPane.

        O app não grava a tela nem captura imagens das janelas.
        """
        alert.addButton(withTitle: "Abrir Ajustes")
        alert.addButton(withTitle: "Agora não")

        if alert.runModal() == .alertFirstButtonReturn {
            AccessibilityHelper.requestTrust()
            AccessibilityHelper.openSettings()
        }
    }
}

extension AppDelegate {
    /// Asks only once at launch, so the app never nags. The menu keeps the option available.
    fileprivate func askForScreenRecordingOnce() {
        let key = "askedScreenRecording"
        guard WindowPreviewProvider.isSupported, !WindowPreviewProvider.isAuthorized,
              !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        showScreenRecordingAlert()
    }

    func showScreenRecordingAlert() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Ativar a prévia das janelas?"
        alert.informativeText = """
        Para mostrar uma miniatura de cada janela, o Ronic DockPane precisa da permissão de Gravação de Tela.

        Em Ajustes do Sistema › Privacidade e Segurança › Gravação de Tela e Áudio do Sistema, ative o Ronic DockPane.

        Sem ela, o painel continua funcionando com a lista de títulos. As imagens ficam só na memória e nada é gravado ou enviado.
        """
        alert.addButton(withTitle: "Abrir Ajustes")
        alert.addButton(withTitle: "Agora não")

        if alert.runModal() == .alertFirstButtonReturn {
            WindowPreviewProvider.requestAccess()
            WindowPreviewProvider.openSettings()
        }
    }
}

/// Renders a README image (`DOCKPANE_SHOT=/path/file.png DockPane`): a desktop with the Dock and the panel open
/// over Terminal. The thumbnails are drawn, not captured, so no real window content ends up in the repository.
enum DemoScreenshot {
    private static let sceneSize = CGSize(width: 1120, height: 440)
    private static let switcherSceneSize = CGSize(width: 1080, height: 470)

    private typealias Sample = (title: String, minimized: Bool, lines: [(String, NSColor)])

    /// Drawn Terminal windows used by both README images.
    private static var samples: [Sample] {
    let green = NSColor(srgbRed: 0.45, green: 0.86, blue: 0.55, alpha: 1)
    let blue = NSColor(srgbRed: 0.45, green: 0.70, blue: 1.00, alpha: 1)
    let pink = NSColor(srgbRed: 0.98, green: 0.47, blue: 0.68, alpha: 1)
    let yellow = NSColor(srgbRed: 0.98, green: 0.83, blue: 0.42, alpha: 1)
    let gray = NSColor(white: 0.62, alpha: 1)
    let white = NSColor(white: 0.92, alpha: 1)

    return [
        ("~ — zsh", false, [
            ("ronic@mac ~ % ls", white),
            ("Desktop    Documents  Downloads  Projects", blue),
            ("ronic@mac ~ % cd Projects/ronic-dockpane", white),
            ("ronic@mac ronic-dockpane % git status", white),
            ("On branch main", gray),
            ("Your branch is up to date with 'origin/main'.", gray),
            ("nothing to commit, working tree clean", green),
            ("ronic@mac ronic-dockpane % ▌", white),
        ]),
        ("DockMonitor.swift — vim", false, [
            ("final class DockMonitor {", pink),
            ("    var onHover: ((DockedApp?) -> Void)?", white),
            ("    private let queryInterval = 0.09", white),
            ("", white),
            ("    func start() {", pink),
            ("        guard eventMonitor == nil else { return }", white),
            ("        // event-driven, no timers", gray),
            ("    }", white),
            ("-- INSERT --", yellow),
        ]),
        ("npm run dev — node", true, [
            ("> web@1.4.0 dev", gray),
            ("> vite", gray),
            ("", white),
            ("  VITE v5.4.2  ready in 312 ms", green),
            ("", white),
            ("  ➜  Local:   http://localhost:5173/", blue),
            ("  ➜  Network: use --host to expose", gray),
            ("  12:04:31 [vite] hmr update /src/App.tsx", yellow),
        ]),
        ("app.log — tail -f", false, [
            ("12:04:02 INFO  server started on :8080", green),
            ("12:04:05 INFO  GET /health 200 2ms", white),
            ("12:04:09 INFO  GET /api/windows 200 14ms", white),
            ("12:04:11 WARN  cache miss: previews/42", yellow),
            ("12:04:12 INFO  POST /api/raise 204 3ms", white),
            ("12:04:15 INFO  GET /api/windows 200 11ms", white),
            ("12:04:18 INFO  GET /health 200 1ms", white),
            ("▌", white),
        ]),
    ]
    }

    static func write(to path: String) {
        let terminalIcon = NSWorkspace.shared.icon(forFile: "/System/Applications/Utilities/Terminal.app")
        let app = DockedApp(pid: 0, name: "Terminal", icon: terminalIcon, itemFrame: .zero, edge: .bottom)

        var windows: [AppWindow] = []
        var previews: [Int: NSImage] = [:]
        for (index, sample) in samples.enumerated() {
            windows.append(AppWindow(id: index, title: sample.title, isMinimized: sample.minimized,
                                     frame: nil, element: AXUIElementCreateSystemWide()))
            previews[index] = terminalThumbnail(lines: sample.lines)
        }

        let model = PanelModel(app: app, windows: windows, showPreviews: true)
        model.previews = previews

        let dockApps = [
            "/System/Library/CoreServices/Finder.app",
            "/System/Applications/Calendar.app",
            "/System/Applications/Utilities/Terminal.app",
            "/System/Applications/Notes.app",
            "/System/Applications/System Settings.app",
        ].map { NSWorkspace.shared.icon(forFile: $0) }

        let scene = ZStack(alignment: .bottom) {
            LinearGradient(
                colors: [Color(red: 0.22, green: 0.14, blue: 0.45), Color(red: 0.05, green: 0.30, blue: 0.50)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            VStack(spacing: 34) {
                WindowListView(model: model, onSelect: { _ in })
                    .background(Color(red: 0.12, green: 0.12, blue: 0.14).opacity(0.94))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
                    .fixedSize()

                HStack(spacing: 10) {
                    ForEach(dockApps.indices, id: \.self) { index in
                        VStack(spacing: 3) {
                            Image(nsImage: dockApps[index]).resizable().frame(width: 58, height: 58)
                            Circle().fill(Color.white.opacity(index == 2 ? 0.85 : 0)).frame(width: 4, height: 4)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(0.16)))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
            }
            .padding(.bottom, 10)
        }
        .frame(width: sceneSize.width, height: sceneSize.height)
        .environment(\.colorScheme, .dark)

        render(scene, size: sceneSize, to: path)
    }

    /// The ⌥Tab switcher over a desktop, with windows of three apps and the second card selected.
    static func writeSwitcher(to path: String) {
        func icon(_ path: String) -> NSImage { NSWorkspace.shared.icon(forFile: path) }
        let terminal = icon("/System/Applications/Utilities/Terminal.app")
        let notes = icon("/System/Applications/Notes.app")
        let finder = icon("/System/Library/CoreServices/Finder.app")

        let entries: [(app: String, icon: NSImage, title: String, thumb: NSImage)] = [
            ("Terminal", terminal, samples[0].title, terminalThumbnail(lines: samples[0].lines)),
            ("Notas", notes, "Ideias para o Ronic", documentThumbnail(accent: NSColor(srgbRed: 0.98, green: 0.80, blue: 0.20, alpha: 1), sidebar: true)),
            ("Finder", finder, "Projects", folderThumbnail()),
            ("Terminal", terminal, samples[1].title, terminalThumbnail(lines: samples[1].lines)),
            ("Notas", notes, "Lista de tarefas", documentThumbnail(accent: NSColor(srgbRed: 0.98, green: 0.80, blue: 0.20, alpha: 1), sidebar: false)),
            ("Terminal", terminal, samples[3].title, terminalThumbnail(lines: samples[3].lines)),
        ]
        var items: [SwitcherItem] = []
        var previews: [Int: NSImage] = [:]
        for (index, entry) in entries.enumerated() {
            let window = AppWindow(id: index, title: entry.title, isMinimized: false, frame: nil,
                                   element: AXUIElementCreateSystemWide())
            items.append(SwitcherItem(id: index, pid: 0, appName: entry.app, icon: entry.icon, window: window))
            previews[index] = entry.thumb
        }
        let model = SwitcherModel(items: items, selection: 1, maxColumns: 3, hiddenCount: 0)
        model.previews = previews

        let scene = ZStack {
            LinearGradient(
                colors: [Color(red: 0.22, green: 0.14, blue: 0.45), Color(red: 0.05, green: 0.30, blue: 0.50)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            SwitcherView(model: model, onSelect: { _ in }, onHover: { _ in }, onClose: { _ in })
                .background(Color(red: 0.12, green: 0.12, blue: 0.14).opacity(0.94))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
                .fixedSize()
        }
        .frame(width: switcherSceneSize.width, height: switcherSceneSize.height)
        .environment(\.colorScheme, .dark)

        render(scene, size: switcherSceneSize, to: path)
    }

    private static func render<V: View>(_ view: V, size: CGSize, to path: String) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)

        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
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
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        host.displayIgnoringOpacity(host.bounds, in: context)
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    /// A drawn Terminal window: title bar with the three buttons and coloured monospaced text.
    private static func terminalThumbnail(lines: [(String, NSColor)]) -> NSImage {
        let thumb = WindowPreviewProvider.thumbnailSize
        let size = NSSize(width: thumb.width * 2, height: thumb.height * 2)
        return NSImage(size: size, flipped: true) { rect in
            NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 1).setFill()
            rect.fill()
            NSColor(white: 0.20, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: rect.width, height: 26).fill()
            for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: 10 + CGFloat(i) * 18, y: 7, width: 12, height: 12)).fill()
            }
            let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            for (index, line) in lines.enumerated() {
                NSAttributedString(string: line.0, attributes: [.font: font, .foregroundColor: line.1])
                    .draw(at: NSPoint(x: 12, y: 36 + CGFloat(index) * 19))
            }
            return true
        }
    }
    /// A drawn light document window (Notes-like): optional sidebar, a heading and grey text lines.
    private static func documentThumbnail(accent: NSColor, sidebar: Bool) -> NSImage {
        let thumb = WindowPreviewProvider.thumbnailSize
        let size = NSSize(width: thumb.width * 2, height: thumb.height * 2)
        return NSImage(size: size, flipped: true) { rect in
            NSColor(white: 0.97, alpha: 1).setFill()
            rect.fill()
            NSColor(white: 0.90, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: rect.width, height: 26).fill()
            for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: 10 + CGFloat(i) * 18, y: 7, width: 12, height: 12)).fill()
            }
            var left: CGFloat = 18
            if sidebar {
                NSColor(white: 0.92, alpha: 1).setFill()
                NSRect(x: 0, y: 26, width: 120, height: rect.height - 26).fill()
                for row in 0..<6 {
                    (row == 0 ? accent.withAlphaComponent(0.55) : NSColor(white: 0.80, alpha: 1)).setFill()
                    NSBezierPath(roundedRect: NSRect(x: 12, y: 42 + CGFloat(row) * 28, width: 96, height: 16),
                                 xRadius: 4, yRadius: 4).fill()
                }
                left = 138
            }
            accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: left, y: 44, width: 150, height: 16), xRadius: 4, yRadius: 4).fill()
            NSColor(white: 0.78, alpha: 1).setFill()
            let widths: [CGFloat] = [0.92, 0.85, 0.95, 0.6, 0.9, 0.8, 0.7, 0.88]
            for (index, width) in widths.enumerated() {
                let available = rect.width - left - 18
                NSBezierPath(roundedRect: NSRect(x: left, y: 78 + CGFloat(index) * 22, width: available * width, height: 10),
                             xRadius: 3, yRadius: 3).fill()
            }
            return true
        }
    }

    /// A drawn Finder window: sidebar and a grid of folder icons.
    private static func folderThumbnail() -> NSImage {
        let thumb = WindowPreviewProvider.thumbnailSize
        let size = NSSize(width: thumb.width * 2, height: thumb.height * 2)
        let folder = NSWorkspace.shared.icon(for: .folder)
        return NSImage(size: size, flipped: true) { rect in
            NSColor(white: 0.97, alpha: 1).setFill()
            rect.fill()
            NSColor(white: 0.90, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: rect.width, height: 26).fill()
            for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: 10 + CGFloat(i) * 18, y: 7, width: 12, height: 12)).fill()
            }
            NSColor(white: 0.92, alpha: 1).setFill()
            NSRect(x: 0, y: 26, width: 110, height: rect.height - 26).fill()
            NSColor(white: 0.80, alpha: 1).setFill()
            for row in 0..<7 {
                NSBezierPath(roundedRect: NSRect(x: 12, y: 42 + CGFloat(row) * 26, width: 84, height: 12),
                             xRadius: 3, yRadius: 3).fill()
            }
            for index in 0..<8 {
                let x = 134 + CGFloat(index % 4) * 74
                let y = 44 + CGFloat(index / 4) * 106
                folder.draw(in: NSRect(x: x, y: y, width: 56, height: 56))
                NSColor(white: 0.70, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: x + 4, y: y + 64, width: 48, height: 9), xRadius: 3, yRadius: 3).fill()
            }
            return true
        }
    }
}
