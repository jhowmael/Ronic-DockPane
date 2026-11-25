import SwiftUI
import AppKit
import ServiceManagement

@main
struct DockPaneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Ronic DockPane", systemImage: "rectangle.stack") {
            MenuContent(state: appDelegate.state, onGrant: appDelegate.showPermissionAlert)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Menu bar menu: permission status, launch at login, quit.
private struct MenuContent: View {
    @ObservedObject var state: AppState
    let onGrant: () -> Void

    var body: some View {
        Text(state.isTrusted ? "Acessibilidade: concedida" : "Acessibilidade: não concedida")

        if !state.isTrusted {
            Button("Conceder permissão…", action: onGrant)
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
    @Published private(set) var launchAtLogin = LaunchAtLogin.isEnabled

    func refresh() {
        isTrusted = AccessibilityHelper.isTrusted
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
    private let panel = FloatingPanelController(minimumWindows: 2)
    private var activationObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon and no app menu.
        NSApp.setActivationPolicy(.accessory)

        if let path = ProcessInfo.processInfo.environment["DOCKPANE_SHOT"] {
            DemoScreenshot.write(to: path)
            NSApp.terminate(nil)
            return
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

/// Renders the panel with sample windows to a PNG for the README: `DOCKPANE_SHOT=/path/file.png DockPane`.
enum DemoScreenshot {
    static func write(to path: String) {
        let icon = NSWorkspace.shared.icon(forFile: "/System/Applications/Utilities/Terminal.app")
        let app = DockedApp(pid: 0, name: "Terminal", icon: icon, itemFrame: .zero, edge: .bottom)

        let samples: [(title: String, minimized: Bool)] = [
            ("~ — zsh", false),
            ("ronic-dockpane — vim", false),
            ("npm run dev — node", true),
            ("logs — tail -f app.log", false),
        ]
        let windows = samples.enumerated().map { index, sample in
            AppWindow(id: index, title: sample.title, isMinimized: sample.minimized,
                      element: AXUIElementCreateSystemWide())
        }

        let content = WindowListView(app: app, windows: windows) { _ in }
            .background(Color(red: 0.13, green: 0.13, blue: 0.15))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(24)
            .environment(\.colorScheme, .dark)

        let host = NSHostingView(rootView: content)
        let size = host.fittingSize
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
}
