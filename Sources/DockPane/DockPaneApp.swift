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
    private var activationObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon and no app menu.
        NSApp.setActivationPolicy(.accessory)

        let environment = ProcessInfo.processInfo.environment
        if let path = environment["DOCKPANE_SHOT"] {
            DemoScreenshot.write(to: path)
            NSApp.terminate(nil)
            return
        }

        // 0.5.0 removed the ⌥Tab/⌘Tab window switcher; drop its leftover settings.
        for key in ["switcherEnabled", "replaceCommandTab", "switcherKeyCode"] {
            UserDefaults.standard.removeObject(forKey: key)
        }

        dockMonitor.onHover = { [weak self] app in
            guard let self else { return }
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

        startMonitoringIfTrusted()
        if !state.isTrusted {
            showPermissionAlert()
        } else {
            askForScreenRecordingOnce()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        dockMonitor.stop()
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

}
