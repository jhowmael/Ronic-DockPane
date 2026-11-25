import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Captures one thumbnail per window with ScreenCaptureKit, like the Windows taskbar preview.
///
/// This is the only part of DockPane that needs the Screen Recording permission. Without it
/// (or before macOS 14, which introduced the one-shot screenshot API) the panel falls back to a
/// plain list of titles.
/// One window to capture. `key` is how the caller finds the thumbnail again.
struct PreviewRequest {
    let key: Int
    let pid: pid_t
    let window: AppWindow
}

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

    /// The last thumbnail of each window, by window ID. It is shown at once the next time a panel opens, and it
    /// stands in for minimized windows, which the system no longer draws. Memory only, pruned to live windows.
    @MainActor private static var cache: [CGWindowID: NSImage] = [:]

    /// Captures thumbnails and hands each one to `deliver` as soon as it is ready (cached images first).
    /// Windows that cannot be captured are skipped.
    static func previews(for requests: [PreviewRequest], deliver: @escaping @MainActor (Int, NSImage) -> Void) async {
        guard #available(macOS 14.0, *), isAuthorized, !requests.isEmpty else { return }

        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else {
            return
        }

        // Match per app, since `AppWindow.id` is only unique inside one app.
        var found: [(key: Int, minimized: Bool, window: SCWindow)] = []
        for (pid, group) in Dictionary(grouping: requests, by: \.pid) {
            let candidates = content.windows.filter {
                $0.owningApplication?.processID == pid && $0.windowLayer == 0
            }
            let matches = match(group.map(\.window), to: candidates)
            for request in group {
                if let scWindow = matches[request.window.id] {
                    found.append((request.key, request.window.isMinimized, scWindow))
                }
            }
        }

        let targets = found
        let live = Set(content.windows.map(\.windowID))
        let cachedKeys: Set<Int> = await MainActor.run {
            cache = cache.filter { live.contains($0.key) }
            var keys = Set<Int>()
            for target in targets {
                if let image = cache[target.window.windowID] {
                    deliver(target.key, image)
                    keys.insert(target.key)
                }
            }
            return keys
        }

        await withTaskGroup(of: (Int, CGWindowID, NSImage?).self) { group in
            // A minimized window is not drawn any more: keep the image taken while it was on screen.
            for target in targets where !(target.minimized && cachedKeys.contains(target.key)) {
                group.addTask { (target.key, target.window.windowID, await capture(target.window)) }
            }
            for await (key, windowID, image) in group {
                guard let image else { continue }
                await MainActor.run {
                    cache[windowID] = image
                    deliver(key, image)
                }
            }
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
