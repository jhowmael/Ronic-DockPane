import SwiftUI
import AppKit

/// Content of the floating panel: the app's icon and name, then one row per window.
struct WindowListView: View {
    let app: DockedApp
    let windows: [AppWindow]
    let onSelect: (AppWindow) -> Void

    private let maxRows = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: 20, height: 20)
                Text(app.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()
                .padding(.horizontal, 8)

            VStack(spacing: 2) {
                ForEach(windows.prefix(maxRows)) { window in
                    WindowRow(window: window, onSelect: onSelect)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)

            if windows.count > maxRows {
                Text("+\(windows.count - maxRows) mais")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
        }
        .frame(width: 280)
    }
}

/// One window. Highlighted while the pointer is over it.
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
