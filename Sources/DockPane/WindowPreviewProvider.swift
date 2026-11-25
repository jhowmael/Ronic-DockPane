import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Captures one thumbnail per window with ScreenCaptureKit, like the Windows taskbar preview.
///
/// This is the only part of DockPane that needs the Screen Recording permission. Without it
/// (or before macOS 14, which introduced the one-shot screenshot API) the panel falls back to a
/// plain list of titles.
enum WindowPreviewProvider {
    /// Longest side of a thumbnail in points; captured at 2x.
    static let thumbnailSize = CGSize(width: 220, height: 138)

    static var isSupported: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    static var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt (first time only) and lists Ronic DockPane under Screen Recording.
    static func requestAccess() {
        _ = CGRequestScreenCaptureAccess()
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Thumbnails keyed by `AppWindow.id`. Windows that cannot be captured are simply missing.
    static func previews(for windows: [AppWindow], pid: pid_t) async -> [Int: NSImage] {
        guard #available(macOS 14.0, *), isAuthorized else { return [:] }

        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else {
            return [:]
        }
        let candidates = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0
        }
        let matches = match(windows, to: candidates)

        return await withTaskGroup(of: (Int, NSImage?).self) { group in
            for (id, scWindow) in matches {
                group.addTask { (id, await capture(scWindow)) }
            }
            var result: [Int: NSImage] = [:]
            for await (id, image) in group {
                if let image { result[id] = image }
            }
            return result
        }
    }

    /// Pairs each Accessibility window with its ScreenCaptureKit window: same title first, then closest frame.
    @available(macOS 14.0, *)
    private static func match(_ windows: [AppWindow], to candidates: [SCWindow]) -> [Int: SCWindow] {
        var free = candidates
        var result: [Int: SCWindow] = [:]

        // Windows with a unique title are matched by title; the rest by geometry.
        for window in windows {
            let sameTitle = free.filter { $0.title == window.title }
            let pick = sameTitle.count == 1 ? sameTitle.first : closest(to: window.frame, in: sameTitle)
            if let pick {
                result[window.id] = pick
                free.removeAll { $0.windowID == pick.windowID }
            }
        }
        for window in windows where result[window.id] == nil {
            if let pick = closest(to: window.frame, in: free) {
                result[window.id] = pick
                free.removeAll { $0.windowID == pick.windowID }
            }
        }
        return result
    }

    @available(macOS 14.0, *)
    private static func closest(to frame: CGRect?, in candidates: [SCWindow]) -> SCWindow? {
        guard let frame else { return candidates.first }
        return candidates.min { distance($0.frame, frame) < distance($1.frame, frame) }
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }

    @available(macOS 14.0, *)
    private static func capture(_ window: SCWindow) async -> NSImage? {
        let frame = window.frame
        guard frame.width > 1, frame.height > 1 else { return nil }

        // Fit inside the thumbnail box, keeping the aspect ratio.
        let scale = min(thumbnailSize.width / frame.width, thumbnailSize.height / frame.height)
        let config = SCStreamConfiguration()
        config.width = max(1, Int(frame.width * scale * 2))
        config.height = max(1, Int(frame.height * scale * 2))
        config.showsCursor = false
        config.capturesAudio = false

        let filter = SCContentFilter(desktopIndependentWindow: window)
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else {
            return nil
        }
        return NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2))
    }
}
