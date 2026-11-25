import AppKit
import ApplicationServices

/// Diagnostics, only when launched with `DOCKPANE_DEBUG=1`.
enum Debug {
    static let enabled = ProcessInfo.processInfo.environment["DOCKPANE_DEBUG"] == "1"
    static func log(_ message: @autoclosure () -> String) {
        if enabled { FileHandle.standardError.write(Data("[DockPane] \(message())\n".utf8)) }
    }
}

/// Which screen edge the Dock sits on (from `com.apple.dock` → `orientation`).
enum DockEdge {
    case bottom, left, right
}

/// A running app whose icon is under the pointer in the Dock.
struct DockedApp {
    let pid: pid_t
    let name: String
    let icon: NSImage
    /// The Dock icon's rectangle, in Cocoa coordinates (origin at the bottom-left).
    let itemFrame: CGRect
    let edge: DockEdge
}

/// A window of another app, read through the Accessibility API.
struct AppWindow: Identifiable {
    let id: Int
    let title: String
    let isMinimized: Bool
    /// Frame in Accessibility coordinates (top-left origin); used to match the window to its capture.
    let frame: CGRect?
    let element: AXUIElement
}

/// Raw Dock hit test result, before it is matched to a running process.
struct DockItemHit {
    let bundleURL: URL?
    let bundleID: String?
    /// The icon's rectangle in Accessibility coordinates (origin at the top-left of the primary screen).
    let axFrame: CGRect
}

/// Every Accessibility call goes through here: AX can block for a while, so never call it on the main thread.
enum AccessibilityHelper {
    static let queue = DispatchQueue(label: "io.github.jhowmael.dockpane.accessibility", qos: .userInitiated)
    /// Dock hit tests get their own queue, so they never wait behind a window list being read.
    static let hitTestQueue = DispatchQueue(label: "io.github.jhowmael.dockpane.hittest", qos: .userInteractive)

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Lists Ronic DockPane in Privacy & Security › Accessibility and shows the system prompt.
    static func requestTrust() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Generic attribute access

    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXPosition" as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, "AXSize" as CFString, &sizeRef) == .success,
              let positionValue = positionRef, let sizeValue = sizeRef,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    // MARK: - Dock

    /// Hit-tests the screen at an Accessibility point and returns the application icon under it, if any.
    static func dockItem(at point: CGPoint) -> DockItemHit? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)

        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              let hitElement = hit else { return nil }

        // The hit can land on a child of the icon, so walk up a few levels to the AXDockItem.
        var current: AXUIElement? = hitElement
        for _ in 0..<4 {
            guard let element = current else { return nil }
            if (attribute(element, "AXRole") as String?) == "AXDockItem" {
                guard (attribute(element, "AXSubrole") as String?) == "AXApplicationDockItem",
                      let axFrame = frame(of: element) else { return nil }
                let url: URL? = attribute(element, "AXURL")
                let bundleID = url.flatMap { Bundle(url: $0)?.bundleIdentifier }
                return DockItemHit(bundleURL: url, bundleID: bundleID, axFrame: axFrame)
            }
            current = attribute(element, "AXParent")
        }
        return nil
    }

    // MARK: - Windows

    /// The app's standard windows that have a title. Minimized windows are included.
    static func windows(for pid: pid_t) -> [AppWindow] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)

        let elements: [AXUIElement] = attribute(app, "AXWindows") ?? []
        var result: [AppWindow] = []
        for element in elements {
            guard (attribute(element, "AXRole") as String?) == "AXWindow",
                  (attribute(element, "AXSubrole") as String?) == "AXStandardWindow",
                  let title = (attribute(element, "AXTitle") as String?)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { continue }

            let minimized: Bool = attribute(element, "AXMinimized") ?? false
            result.append(AppWindow(id: result.count, title: title, isMinimized: minimized,
                                    frame: frame(of: element), element: element))
        }
        return result
    }

    /// Windows of several apps, read in parallel so one slow app does not hold up the rest.
    static func windows(forApps pids: [pid_t]) -> [pid_t: [AppWindow]] {
        let box = ResultBox()
        DispatchQueue.concurrentPerform(iterations: pids.count) { index in
            box.set(windows(for: pids[index]), for: pids[index])
        }
        return box.all
    }

    /// Collects results written from several threads.
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var byPID: [pid_t: [AppWindow]] = [:]

        func set(_ windows: [AppWindow], for pid: pid_t) {
            lock.lock()
            byPID[pid] = windows
            lock.unlock()
        }

        var all: [pid_t: [AppWindow]] {
            lock.lock()
            defer { lock.unlock() }
            return byPID
        }
    }

    /// Presses the window's own close button, so the app closes it as if the user clicked the red button.
    static func close(_ window: AppWindow) {
        guard let button: AXUIElement = attribute(window.element, "AXCloseButton") else { return }
        AXUIElementPerformAction(button, "AXPress" as CFString)
    }

    /// Unminimizes the window if needed, raises it, and activates its app.
    static func raise(_ window: AppWindow, pid: pid_t) {
        if window.isMinimized {
            AXUIElementSetAttributeValue(window.element, "AXMinimized" as CFString, kCFBooleanFalse)
        }
        AXUIElementSetAttributeValue(window.element, "AXMain" as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window.element, "AXRaise" as CFString)
        // Since macOS 14 a background app may be refused when it activates another one; through Accessibility
        // the app is brought to the front either way.
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        AXUIElementSetAttributeValue(app, "AXFrontmost" as CFString, kCFBooleanTrue)

        DispatchQueue.main.async {
            guard let app = NSRunningApplication(processIdentifier: pid) else { return }
            if #available(macOS 14.0, *) {
                app.activate()
            } else {
                app.activate(options: [.activateIgnoringOtherApps])
            }
        }
    }
}
