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

    private let maxListRows = 12
    private let maxCards = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.horizontal, 8)
            if model.showPreviews {
                cards
            } else {
                list
            }
        }
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
        let count = min(model.windows.count, maxCards)
        return model.app.edge == .bottom ? min(count, 4) : 1
    }

    private var cards: some View {
        let visible = Array(model.windows.prefix(maxCards))
        let rows = stride(from: 0, to: visible.count, by: columns).map {
            Array(visible[$0..<min($0 + columns, visible.count)])
        }
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 6) {
                    ForEach(rows[index]) { window in
                        PreviewCard(window: window, app: model.app,
                                    image: model.previews[window.id], onSelect: onSelect)
                    }
                }
            }
            if model.windows.count > maxCards {
                Text("+\(model.windows.count - maxCards) mais")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
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
        .padding(8)
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

/// One window as a thumbnail with its title above. Highlighted while the pointer is over it.
private struct PreviewCard: View {
    let window: AppWindow
    let app: DockedApp
    let image: NSImage?
    let onSelect: (AppWindow) -> Void

    @State private var isHovered = false

    private var size: CGSize { WindowPreviewProvider.thumbnailSize }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: 14, height: 14)
                Text(window.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .frame(width: size.width)

            thumbnail
                .frame(width: size.width, height: size.height)
                .background(Color.black.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                )
        }
        .foregroundStyle(isHovered ? Color.white : Color.primary)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.accentColor.opacity(0.85) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
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
            // Not captured (yet, or the window cannot be captured): show the app icon.
            Image(nsImage: app.icon)
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 48)
                .opacity(0.8)
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
