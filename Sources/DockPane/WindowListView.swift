import SwiftUI
import AppKit

/// What the panel shows. The controller updates it; previews arrive after the panel is already visible.
final class PanelModel: ObservableObject {
    @Published var app: DockedApp
    @Published var windows: [AppWindow]
    /// Thumbnails keyed by `AppWindow.id`.
    @Published var previews: [Int: NSImage] = [:]
    /// Thumbnail cards when Screen Recording is granted; a plain list of titles otherwise.
    @Published var showPreviews: Bool
    /// Cards are shown but Screen Recording is missing, so they only have placeholders.
    @Published var needsPermission: Bool
    /// Where each card is drawn (top-left origin, in the panel), for the close animation. Not published.
    var cardFrames: [Int: CGRect] = [:]

    init(app: DockedApp, windows: [AppWindow], showPreviews: Bool, needsPermission: Bool = false) {
        self.app = app
        self.windows = windows
        self.showPreviews = showPreviews
        self.needsPermission = needsPermission
    }
}

/// Content of the floating panel: the app's icon and name, then its windows.
struct WindowListView: View {
    @ObservedObject var model: PanelModel
    let onSelect: (AppWindow) -> Void
    var onEnablePreviews: () -> Void = {}
    var onClose: (AppWindow) -> Void = { _ in }
    /// The app is running with no windows: reopen one (same as clicking its Dock icon).
    var onReopenApp: () -> Void = {}
    /// Quits the app for real.
    var onQuitApp: () -> Void = {}

    private let maxListRows = 12
    private let maxCards = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.windows.isEmpty {
                AppCard(app: model.app, onReopen: onReopenApp, onQuit: onQuitApp)
                    .padding(5)
            } else if model.showPreviews {
                // Each card already shows the app icon and the window title, so no header here.
                cards
                    .onPreferenceChange(CardFramesKey.self) { frames in model.cardFrames = frames }
            } else {
                header
                Divider().padding(.horizontal, 8)
                list
            }
        }
        .coordinateSpace(name: CardFramesKey.space)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: model.app.icon)
                .resizable()
                .frame(width: 20, height: 20)
            Text(model.app.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    // MARK: - Thumbnails

    /// Side docks get a single column; a bottom dock spreads the cards in up to four columns, like the Windows taskbar.
    private var columns: Int {
        let count = max(1, min(model.windows.count, maxCards))
        return model.app.edge == .bottom ? min(count, 4) : 1
    }

    private var cards: some View {
        let visible = Array(model.windows.prefix(maxCards))
        let rows = stride(from: 0, to: visible.count, by: columns).map {
            Array(visible[$0..<min($0 + columns, visible.count)])
        }
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 4) {
                    ForEach(rows[index]) { window in
                        // The Dock already shows the app's name over the icon, so the cards skip their title row.
                        PreviewCard(window: window, icon: model.app.icon,
                                    image: model.previews[window.id], onSelect: onSelect, onClose: onClose,
                                    showsTitle: false)
                    }
                }
            }
            if model.windows.count > maxCards {
                Text("+\(model.windows.count - maxCards) mais")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            }
            if model.needsPermission {
                Button(action: onEnablePreviews) {
                    Label("Ative a Gravação de Tela para ver a prévia das janelas", systemImage: "eye")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.vertical, 5)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity)
                        .background(Capsule().fill(Color.accentColor.opacity(0.9)))
                        .foregroundStyle(Color.white)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(5)
    }

    // MARK: - Plain list (no Screen Recording permission)

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 2) {
                ForEach(model.windows.prefix(maxListRows)) { window in
                    WindowRow(window: window, onSelect: onSelect)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)

            if model.windows.count > maxListRows {
                Text("+\(model.windows.count - maxListRows) mais")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
        }
        .frame(width: 280)
    }
}

/// Collects each card's frame in the panel, keyed by window id.
struct CardFramesKey: PreferenceKey {
    static let space = "panel"
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Card for an app that is running but has no open window (closed with the red button, or hidden).
private struct AppCard: View {
    let app: DockedApp
    let onReopen: () -> Void
    let onQuit: () -> Void

    @State private var isHovered = false

    private var size: CGSize { WindowPreviewProvider.thumbnailSize }

    var body: some View {
        // No title row: the Dock shows the app's name right under the panel.
        VStack(alignment: .leading, spacing: 5) {
            VStack(spacing: 8) {
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: 56, height: 56)
                Text("Nenhuma janela aberta")
                    .font(.system(size: 12, weight: .medium))
                Text("Clique para abrir uma nova")
                    .font(.system(size: 10))
                    .opacity(0.7)
            }
            .frame(width: size.width, height: size.height)
            .background(Color.black.opacity(0.25))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
        }
        .foregroundStyle(isHovered ? Color.white : Color.primary)
        .padding(6)
        .overlay(alignment: .topLeading) {
            if isHovered {
                Button(action: onQuit) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.red.opacity(0.9)))
                }
                .buttonStyle(.plain)
                .help("Encerrar \(app.name)")
                .padding(4)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.accentColor.opacity(0.85) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onReopen)
    }
}

/// One window as a thumbnail with its title above. Highlighted while the pointer is over it,
/// or, in the window switcher, while it is the selected one.
struct PreviewCard: View {
    let window: AppWindow
    let icon: NSImage
    let image: NSImage?
    let onSelect: (AppWindow) -> Void
    let onClose: (AppWindow) -> Void
    /// Set by the window switcher, where the keyboard decides the highlight. `nil` follows the pointer.
    var isSelected: Bool? = nil
    var onHover: () -> Void = {}
    /// The icon and title row above the thumbnail. Without it the title shows on hover, and under the
    /// placeholder while there is no thumbnail.
    var showsTitle = true

    @State private var isHovered = false

    private var isHighlighted: Bool { isSelected ?? isHovered }

    private var size: CGSize { WindowPreviewProvider.thumbnailSize }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if showsTitle {
                HStack(spacing: 6) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 14, height: 14)
                    Text(window.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .frame(width: size.width)
            }

            thumbnail
                .frame(width: size.width, height: size.height)
                .background(Color.black.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                )
        }
        .foregroundStyle(isHighlighted ? Color.white : Color.primary)
        .padding(6)
        .overlay(alignment: .topLeading) {
            if isHovered {
                Button { onClose(window) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.red.opacity(0.9)))
                }
                .buttonStyle(.plain)
                .help("Fechar janela")
                .padding(4)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHighlighted ? Color.accentColor.opacity(0.85) : Color.clear)
        )
        .contentShape(Rectangle())
        .background(GeometryReader { proxy in
            Color.clear.preference(key: CardFramesKey.self,
                                   value: [window.id: proxy.frame(in: .named(CardFramesKey.space))])
        })
        .help(showsTitle ? "" : window.title)
        .onHover { hovering in
            isHovered = hovering
            if hovering { onHover() }
        }
        .onTapGesture { onSelect(window) }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .opacity(window.isMinimized ? 0.55 : 1)
        } else {
            // Not captured (yet, or the window cannot be captured): the app icon, and the title if it is not above.
            VStack(spacing: 6) {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .opacity(0.8)
                if !showsTitle {
                    Text(window.title)
                        .font(.system(size: 11))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                }
            }
        }
    }
}

/// One window in the plain list.
private struct WindowRow: View {
    let window: AppWindow
    let onSelect: (AppWindow) -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: window.isMinimized ? "minus.rectangle" : "macwindow")
                .font(.system(size: 11))
                .frame(width: 16)
            Text(window.title)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .foregroundStyle(isHovered ? Color.white : Color.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onSelect(window) }
    }
}
