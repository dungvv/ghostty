import SwiftUI

/// The left panel: every tab open in this window.
///
/// Each row shows the tab's title and, dimmed on the right, the program
/// running in it. Clicking a row brings that tab forward.
struct TerminalTabsSidebar: View {
    @ObservedObject var model: TerminalTabsModel

    /// Space to leave at the top for the traffic lights when the window has no
    /// titlebar of its own.
    var topInset: CGFloat

    /// Called when the user asks for a new tab.
    var onNewTab: (() -> Void)?

    @State private var hovered: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if model.tabs.isEmpty {
                Text("No tabs")
                    .font(OttyTheme.detail)
                    .foregroundStyle(OttyTheme.secondaryText)
                    .padding(.horizontal, OttyTheme.panelPadding + 4)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(model.tabs) { tab in
                            row(tab)
                        }
                    }
                    .padding(.horizontal, OttyTheme.panelPadding - 2)
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(OttyTheme.panel)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text("TABS")
                .font(OttyTheme.caption)
                .tracking(0.8)
                .foregroundStyle(OttyTheme.secondaryText)

            Spacer()

            if let onNewTab {
                Button(action: onNewTab) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(OttyTheme.secondaryText)
                }
                .buttonStyle(.plain)
                .help("New Tab")
            }
        }
        .padding(.top, topInset)
        .padding(.horizontal, OttyTheme.panelPadding + 4)
        .padding(.bottom, 8)
    }

    private func row(_ tab: TerminalTabsModel.Tab) -> some View {
        HStack(spacing: 8) {
            Text(tab.title)
                .font(OttyTheme.body)
                .foregroundStyle(tab.isSelected ? OttyTheme.primaryText : OttyTheme.tabTitle)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if !tab.process.isEmpty {
                Text(tab.process)
                    .font(OttyTheme.detail)
                    .foregroundStyle(OttyTheme.secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: OttyTheme.rowHeight)
        .background(background(for: tab))
        .clipShape(RoundedRectangle(cornerRadius: OttyTheme.rowCornerRadius))
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? tab.id : (hovered == tab.id ? nil : hovered) }
        .onTapGesture { model.select(id: tab.id) }
        .contextMenu {
            Button("Close Tab") { model.close(id: tab.id) }
        }
    }

    private func background(for tab: TerminalTabsModel.Tab) -> Color {
        if tab.isSelected { return OttyTheme.selection }
        if hovered == tab.id { return OttyTheme.hover }
        return .clear
    }
}
