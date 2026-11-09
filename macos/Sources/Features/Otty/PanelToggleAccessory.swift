import AppKit
import SwiftUI

/// The panel show/hide buttons, living in the window's titlebar.
///
/// A titlebar accessory rather than a button floating over the terminal so
/// the toggles sit on the same row as the close/minimise/zoom buttons, the
/// way Otty arranges them, and so hiding a panel gives all of its space back
/// to the terminal instead of leaving a control behind.
@MainActor
final class PanelToggleAccessory: NSTitlebarAccessoryViewController {
    /// Which panel this button belongs to, which is also which end of the
    /// titlebar it sits at: a control for the left panel belongs on the left.
    enum Side {
        case leading
        case trailing
    }

    private let controller: BaseTerminalController

    init(controller: BaseTerminalController, side: Side) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)

        let hosting = NSHostingView(
            rootView: PanelToggleView(controller: controller, side: side))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.frame = NSRect(x: 0, y: 0, width: 34, height: 28)
        view = container

        layoutAttribute = side == .leading ? .left : .right
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Add both accessories to `window`, unless they are already there.
    static func install(on window: NSWindow, controller: BaseTerminalController) {
        guard !window.titlebarAccessoryViewControllers.contains(where: {
            $0 is PanelToggleAccessory
        }) else { return }
        for side: Side in [.leading, .trailing] {
            window.addTitlebarAccessoryViewController(
                PanelToggleAccessory(controller: controller, side: side))
        }
    }
}

private struct PanelToggleView: View {
    @ObservedObject var controller: BaseTerminalController
    let side: PanelToggleAccessory.Side

    var body: some View {
        switch side {
        case .leading:
            toggle(
                icon: "sidebar.leading",
                on: controller.tabSidebarIsVisible,
                help: controller.tabSidebarIsVisible
                    ? "Hide Tab Sidebar (⌃⌘S)"
                    : "Show Tab Sidebar (⌃⌘S)"
            ) {
                controller.tabSidebarIsVisible.toggle()
            }
            .padding(.leading, 6)

        case .trailing:
            toggle(
                icon: "sidebar.trailing",
                on: controller.infoPanelIsVisible,
                help: controller.infoPanelIsVisible
                    ? "Hide Info Panel (⌃⌘I)"
                    : "Show Info Panel (⌃⌘I)"
            ) {
                controller.infoPanelIsVisible.toggle()
            }
            .padding(.trailing, 12)
        }
    }

    private func toggle(
        icon: String,
        on: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                // A shown panel reads as the active state, which is the only
                // thing distinguishing the two otherwise identical icons.
                .foregroundStyle(on ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
